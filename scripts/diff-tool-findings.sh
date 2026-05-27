#!/usr/bin/env bash
set -euo pipefail

# Compare tool-update findings against current data.
# Categorizes changes: structural (verifiable) vs editorial (notes-only).
# Filters out price fields (price-update scope) and protected fields.
#
# Usage: ./scripts/diff-tool-findings.sh <findings.json> <data-file.json>
# Output: JSON to stdout.

FINDINGS="$1"
DATA_FILE="$2"

if [[ ! -f "$FINDINGS" ]] || [[ ! -f "$DATA_FILE" ]]; then
  echo "ERROR: Missing input file" >&2
  exit 1
fi

if ! jq empty "$FINDINGS" 2>/dev/null; then
  echo "ERROR: $FINDINGS is not valid JSON" >&2
  exit 1
fi

slug=$(jq -r '.slug' "$FINDINGS")
status=$(jq -r '.status // "unknown"' "$FINDINGS")
source_url=$(jq -r '.source_url // "unknown"' "$FINDINGS")
fetch_method=$(jq -r '.fetch_method // "unknown"' "$FINDINGS")
today="${DATE:-$(date -u +%Y-%m-%d)}"
# Days a plan must be missing from proposed.plans before auto-remove eligibility.
# 21 = 3 weekly tool-update cycles; conservative against single-cycle vendor outages.
removal_threshold_days="${REMOVAL_THRESHOLD_DAYS:-21}"

# Unverified findings — skip comparison
if [[ "$status" == "unverified" ]]; then
  jq -n --arg slug "$slug" --arg source_url "$source_url" \
    '{slug: $slug, has_changes: false, has_structural_changes: false,
      status: "unverified", source_url: $source_url, changes: [], warnings: []}'
  exit 0
fi

# Check that proposed object exists
if ! jq -e '.proposed' "$FINDINGS" >/dev/null 2>&1; then
  echo "ERROR: findings missing 'proposed' object" >&2
  exit 1
fi

# Compare proposed against current data
# Output: {has_changes, has_structural_changes, changes[], warnings[]}
jq -n \
  --argjson proposed "$(jq '.proposed' "$FINDINGS")" \
  --argjson current "$(cat "$DATA_FILE")" \
  --arg slug "$slug" \
  --arg source_url "$source_url" \
  --arg fetch_method "$fetch_method" \
  --arg today "$today" \
  --arg finding_status "$status" \
  --argjson removal_threshold_days "$removal_threshold_days" \
  '
  # Price fields — owned by price-update, skip these
  def is_price_field:
    . as $key |
    ($key | test("base_price\\.amount$")) or
    ($key | test("overage\\.input_per_million$")) or
    ($key | test("overage\\.output_per_million$")) or
    ($key | test("overage\\.price_per_unit$"));

  # Protected fields — never auto-modified, unless first-pass flag is set
  def is_protected_field:
    . as $key |
    if ($current._capabilities_first_pass // false) then
      false  # When flag set, surface capability diffs for validator review
    else
      ($key | startswith("capabilities."))
    end;

  # Structural fields — verifiable claims, trigger validation
  def is_structural_field:
    . as $key |
    ($key | test("^vendor\\.")) or
    ($key | test("\\.name$")) or
    ($key | test("\\.category$")) or
    ($key | test("overage\\.unit$")) or
    ($key | test("overage\\.mechanism$")) or
    ($key | test("overage\\.model$")) or
    ($key | test("\\.platform")) or
    ($key | test("^platform\\."));

  # Flatten JSON to key-value pairs (leaf nodes only)
  def flatten_leaves:
    [paths(scalars) as $p | {key: ($p | map(tostring) | join(".")), value: getpath($p)}]
    | from_entries;

  # Strip price, protected, and meta fields before comparison.
  # Capabilities is conditionally protected based on _capabilities_first_pass.
  def strip_excluded:
    (if ($current._capabilities_first_pass // false) then
      del(.verification_override, ._notes_first_pass, ._capabilities_first_pass)
     else
      del(.capabilities, .verification_override, ._notes_first_pass, ._capabilities_first_pass)
     end) |
    walk(if type == "object" then
      del(.amount, ._last_seen_on_page) |
      (if has("input_per_million") then del(.input_per_million) else . end) |
      (if has("output_per_million") then del(.output_per_million) else . end) |
      (if has("price_per_unit") then del(.price_per_unit) else . end)
    else . end);

  # Extract operator-curated transparency markers from a notes string.
  # Format: UNVERIFIED:, UNVERIFIED_<UPPER>:, or UNCONFIRMED: followed by text up to ; or end.
  def operator_markers_in($s):
    if ($s | type) == "string" then
      [$s | scan("(?:UNVERIFIED(?:_[A-Z]+)?|UNCONFIRMED):[^;]+")]
    else [] end;

  # True if every operator marker present in $old is preserved verbatim in $new.
  def notes_change_safe($old; $new):
    ((operator_markers_in($old // "")) - (operator_markers_in($new // ""))) | length == 0;

  # Normalize proposed.plans order to match current.plans order (by .id).
  # Plans missing from current append at the end in their proposed order.
  # Removes the agent-side cosmetic-reorder noise that path-based diffs
  # would otherwise flag as ~N changes per existing plan.
  ($proposed.plans | map({key: .id, value: .}) | from_entries) as $prop_by_id |
  ($current.plans | map(.id)) as $orig_ids |
  ($proposed | .plans = (
    [$orig_ids[] | $prop_by_id[.] // empty] +
    [$proposed.plans[] | select(.id as $i | ($orig_ids | index($i)) == null)]
  )) as $proposed |

  ($current | strip_excluded | flatten_leaves) as $cur |
  ($proposed | strip_excluded | flatten_leaves) as $prop |

  # Build plan ID lookup for context
  ([$current.plans[]? | {(.id): true}] | add // {}) as $current_plan_ids |
  ([$proposed.plans[]? | {(.id): true}] | add // {}) as $proposed_plan_ids |

  # idx → plan_id maps for emitting plan_id sibling on plans-scoped changes.
  # Apply matches verdicts on (plan_id, leaf-suffix, new) — index becomes
  # informational. Proposed-side first (reordered to current order, with new
  # plans appended); current-side as fallback for removed-field branch where
  # the path comes from $cur (an index in proposed-side may not exist there).
  ($proposed.plans // [] | to_entries
    | map({key: (.key|tostring), value: .value.id}) | from_entries) as $idx_to_id_proposed |
  ($current.plans // [] | to_entries
    | map({key: (.key|tostring), value: .value.id}) | from_entries) as $idx_to_id_current |

  def plan_id_for($field):
    ($field | capture("^plans\\.(?<idx>[0-9]+)\\.") // null) as $m
    | if $m == null then null
      else ($idx_to_id_proposed[$m.idx] // $idx_to_id_current[$m.idx] // null)
      end;

  def with_plan_id:
    . as $c
    | (plan_id_for($c.field)) as $pid
    | if $pid == null then $c else $c + {plan_id: $pid} end;

  # Detect plan removals (in current but missing from proposed)
  [$current.plans[]? | .id | select($proposed_plan_ids[.] != true)] as $removed_plans |

  # Indices in $current.plans of removed plans — needed to suppress the
  # field-level diff noise these generate. Paths in the flattened comparison use
  # array indices (plans.<idx>.X), not plan IDs; the previous filter matched by
  # ID and silently did nothing. The 2026-05-20 cursor case showed 16 spurious
  # "field removed" entries reaching the validator as a result.
  [$current.plans | to_entries[] | select(.value.id as $i | ($removed_plans | index($i)) != null) | .key | tostring] as $removed_indices |

  # Detect new plans (in proposed but not current).
  # Emit {id, idx} where idx is the position in the reordered $proposed.plans —
  # this matches the path the validator uses (plans.<idx>.<field>), so the apply
  # gate can resolve per-field verdicts for new plans the same way it does for
  # existing ones (the 5eebbe9 pattern).
  [$proposed.plans | to_entries[] | select($current_plan_ids[.value.id] != true)
    | {id: .value.id, idx: .key}] as $new_plans |

  # Field-level changes (excluding price and protected).
  # Each plans-scoped change gets a plan_id sibling via with_plan_id (the apply
  # gate matches on plan_id, not on the numeric index in field — which drifts
  # whenever proposed/current array lengths differ).
  [
    # Changed fields
    ($cur | to_entries[] |
      select($prop[.key] != null and ($prop[.key] | tostring) != (.value | tostring)) |
      select(.key | is_price_field | not) |
      select(.key | is_protected_field | not) |
      {
        field: .key,
        old: .value,
        new: $prop[.key],
        category: (if .key | is_structural_field then "structural" else "editorial" end)
      } | with_plan_id
    ),
    # Added fields (in proposed, not in current)
    ($prop | to_entries[] |
      select($cur[.key] == null) |
      select(.value != null) |
      select(.key | is_price_field | not) |
      select(.key | is_protected_field | not) |
      {
        field: .key,
        old: null,
        new: .value,
        category: (if .key | is_structural_field then "structural" else "editorial" end)
      } | with_plan_id
    ),
    # Removed fields (in current, not in proposed) — excluding plan-level removals.
    # Plans missing from proposed.plans get their own plan_removal_pending/eligible
    # warning; their per-field "removals" are noise and should not reach validator.
    ($cur | to_entries[] |
      select($prop[.key] == null) |
      select(.value != null) |
      select(.key | is_price_field | not) |
      select(.key | is_protected_field | not) |
      # Suppress fields under indices that belong to removed plans.
      # NOTE: bind the index to a named var ($i) — using bare `.` inside the
      # pipeline rebinds to $k after `| $k`, which makes the startswith check
      # silently false. Same shape of bug as the original ID-based filter.
      select(.key as $k | [$removed_indices[] as $i | $k | startswith("plans." + $i + ".")] | any | not) |
      {
        field: .key,
        old: .value,
        new: null,
        category: (if .key | is_structural_field then "structural" else "editorial" end)
      } | with_plan_id
    )
  ] as $changes |

  # Operator-marker filter: strip notes changes that drop or modify operator markers.
  [$changes[] | select(
    if (.field | test("\\.notes$")) then notes_change_safe(.old; .new)
    else true end)] as $filtered_changes |
  [$changes[] | select(
    if (.field | test("\\.notes$")) then notes_change_safe(.old; .new) | not
    else false end)] as $blocked_marker_changes |

  # Warnings for plan removals — temporal-persistence gate (Fix 2, 2026-05-24).
  # A plan missing from the agent proposed.plans is not enough evidence to
  # auto-remove (vendors rarely publish "X discontinued" text; absence-of-listing
  # is the same weak evidence the 874523e prompt rule kept failing to constrain).
  # Instead: compute age vs ._last_seen_on_page on the current data file. Auto-
  # remove only after the plan has been absent for $removal_threshold_days
  # consecutive days, AND the current findings successfully fetched the page
  # (status != unverified — already short-circuited at line 30, but checked here
  # for clarity).
  def days_between($from; $to):
    (($to | strptime("%Y-%m-%d") | mktime) - ($from | strptime("%Y-%m-%d") | mktime)) / 86400 | floor;

  ([$current.plans[]? | {key: .id, value: ._last_seen_on_page}] | from_entries) as $last_seen_by_id |

  [$removed_plans[] | . as $pid |
    ($last_seen_by_id[$pid] // null) as $last_seen |
    (if $last_seen == null then null else days_between($last_seen; $today) end) as $days |
    if $last_seen == null then
      {type: "plan_removal_pending", plan_id: $pid, last_seen_on_page: null, days_absent: null,
       message: "Plan missing from proposed; no _last_seen_on_page recorded — pending operator review"}
    elif ($days >= $removal_threshold_days) and ($finding_status != "unverified") then
      {type: "plan_removal_eligible", plan_id: $pid, last_seen_on_page: $last_seen, days_absent: $days,
       message: "Plan absent from page for \($days) days (≥ \($removal_threshold_days)) — auto-remove eligible"}
    else
      {type: "plan_removal_pending", plan_id: $pid, last_seen_on_page: $last_seen, days_absent: $days,
       message: "Plan absent from page for \($days) days (< \($removal_threshold_days)) — pending"}
    end
  ] as $warnings |

  # New plan warnings
  [$new_plans[] | {type: "plan_addition", plan_id: .id, message: "New plan proposed — requires validation"}] as $new_plan_warnings |

  # plan_removal_eligible triggers an apply-side removal action, so it counts
  # toward has_changes. plan_removal_pending is informational only.
  ([$warnings[] | select(.type == "plan_removal_eligible")] | length) as $eligible_count |
  ($filtered_changes | map(select(.category == "structural")) | length > 0) as $has_structural |
  ($filtered_changes | length > 0 or ($new_plans | length > 0) or ($eligible_count > 0)) as $has_changes |

  {
    slug: $slug,
    has_changes: $has_changes,
    has_structural_changes: ($has_structural or ($new_plans | length > 0) or ($eligible_count > 0)),
    source_url: $source_url,
    fetch_method: $fetch_method,
    status: (if $has_changes then "changes_found" else "reviewed" end),
    changes: $filtered_changes,
    new_plans: $new_plans,
    warnings: ($warnings + $new_plan_warnings),
    blocked_marker_changes: $blocked_marker_changes
  }
  '
