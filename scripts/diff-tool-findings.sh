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
      del(.amount) |
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

  # Detect plan removals (in current but missing from proposed)
  [$current.plans[]? | .id | select($proposed_plan_ids[.] != true)] as $removed_plans |

  # Detect new plans (in proposed but not current)
  [$proposed.plans[]? | .id | select($current_plan_ids[.] != true)] as $new_plans |

  # Field-level changes (excluding price and protected)
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
      }
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
      }
    ),
    # Removed fields (in current, not in proposed) — excluding plan-level removals
    ($cur | to_entries[] |
      select($prop[.key] == null) |
      select(.value != null) |
      select(.key | is_price_field | not) |
      select(.key | is_protected_field | not) |
      # Skip fields belonging to removed plans (handled separately as warnings)
      select(.key as $k | [$removed_plans[] | $k | startswith("plans." + .)] | any | not) |
      {
        field: .key,
        old: .value,
        new: null,
        category: (if .key | is_structural_field then "structural" else "editorial" end)
      }
    )
  ] as $changes |

  # Operator-marker filter: strip notes changes that drop or modify operator markers.
  [$changes[] | select(
    if (.field | test("\\.notes$")) then notes_change_safe(.old; .new)
    else true end)] as $filtered_changes |
  [$changes[] | select(
    if (.field | test("\\.notes$")) then notes_change_safe(.old; .new) | not
    else false end)] as $blocked_marker_changes |

  # Warnings for plan removals
  [$removed_plans[] | {type: "plan_removal", plan_id: ., message: "Plan missing from proposed — not auto-removed"}] as $warnings |

  # New plan warnings
  [$new_plans[] | {type: "plan_addition", plan_id: ., message: "New plan proposed — requires validation"}] as $new_plan_warnings |

  ($filtered_changes | map(select(.category == "structural")) | length > 0) as $has_structural |
  ($filtered_changes | length > 0 or ($new_plans | length > 0)) as $has_changes |

  {
    slug: $slug,
    has_changes: $has_changes,
    has_structural_changes: ($has_structural or ($new_plans | length > 0)),
    source_url: $source_url,
    fetch_method: $fetch_method,
    status: (if $has_changes then "changes_found" else "reviewed" end),
    changes: $filtered_changes,
    new_plans: $new_plans,
    warnings: ($warnings + $new_plan_warnings),
    blocked_marker_changes: $blocked_marker_changes
  }
  '
