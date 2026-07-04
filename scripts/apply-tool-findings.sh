#!/usr/bin/env bash
set -euo pipefail

# Apply tool-update changes to a data file.
# Merges proposed JSON but preserves price fields and capabilities.
# Only applies changes confirmed by the validation verdict.
# All changes (structural and editorial) require confirmation.
#
# Usage: ./scripts/apply-tool-findings.sh <findings.json> <diff-results.json> <data-file.json> [validated.json]
# Exit 0: success (changes applied or nothing to apply).
# Exit 1: invalid input.

FINDINGS="$1"
DIFF_RESULTS="$2"
DATA_FILE="$3"
VALIDATED="${4:-}"

if [[ ! -f "$FINDINGS" ]] || [[ ! -f "$DIFF_RESULTS" ]] || [[ ! -f "$DATA_FILE" ]]; then
  echo "ERROR: Missing input file" >&2
  exit 1
fi

# Capture _capabilities_first_pass BEFORE clearing — drives merge logic below.
caps_first_pass=$(jq -r '._capabilities_first_pass // false' "$DATA_FILE")

# Temporal persistence bumper (Fix 2, 2026-05-24; observation-gated 2026-06-14).
# When the research agent successfully fetched the vendor page, only plans it
# marked observed this fetch (proposed.plans[]._last_seen_on_page == today) get
# their ._last_seen_on_page advanced to today. Plans listed from prior knowledge
# but not seen keep their existing value, so the agent's "not visible this cycle"
# signal stays load-bearing for the auto-removal clock.
# On "unverified" findings, leave _last_seen_on_page untouched — a vendor-page
# outage shouldn't accelerate the auto-removal clock.
DATE="${DATE:-$(date -u +%Y-%m-%d)}"
finding_status=$(jq -r '.status // "unknown"' "$FINDINGS" 2>/dev/null || echo "unknown")
if [[ "$finding_status" == "reviewed" || "$finding_status" == "changes_found" ]]; then
  BUMP_DATE="$DATE"
else
  BUMP_DATE=""
fi

# Always clear _notes_first_pass — tool-update has now seen this data,
# regardless of whether changes are about to land. Subsequent cycles return
# to standard preserve-existing behavior.
if jq -e '._notes_first_pass' "$DATA_FILE" >/dev/null 2>&1; then
  jq 'del(._notes_first_pass)' "$DATA_FILE" > "${DATA_FILE}.tmp" && mv "${DATA_FILE}.tmp" "$DATA_FILE"
  echo "  Cleared _notes_first_pass flag on $(basename "$DATA_FILE")"
fi

# Same pattern for _capabilities_first_pass.
if jq -e '._capabilities_first_pass' "$DATA_FILE" >/dev/null 2>&1; then
  jq 'del(._capabilities_first_pass)' "$DATA_FILE" > "${DATA_FILE}.tmp" && mv "${DATA_FILE}.tmp" "$DATA_FILE"
  echo "  Cleared _capabilities_first_pass flag on $(basename "$DATA_FILE")"
fi

# Bump _last_seen_on_page for plans the agent marked observed this fetch
# (proposed.plans[]._last_seen_on_page == today). Runs even on no-change cycles so
# observed plans get re-stamped. Plans listed but not observed keep their existing
# value — their clock keeps aging toward removal-eligibility.
if [[ -n "$BUMP_DATE" ]]; then
  jq --arg bump_date "$BUMP_DATE" \
     --argjson observed_ids "$(jq --arg d "$BUMP_DATE" '[.proposed.plans[]? | select(._last_seen_on_page == $d) | .id]' "$FINDINGS")" '
    .plans |= map(
      . as $p |
      if ($observed_ids | index($p.id)) != null
      then ._last_seen_on_page = $bump_date
      else .
      end
    )
  ' "$DATA_FILE" > "${DATA_FILE}.tmp" && mv "${DATA_FILE}.tmp" "$DATA_FILE"
fi

has_changes=$(jq -r '.has_changes' "$DIFF_RESULTS")
if [[ "$has_changes" != "true" ]]; then
  echo "No changes to apply (last_seen bumped where applicable)"
  exit 0
fi

# Build confirmed verdicts from validator (empty arrays if no verdict).
# Plans-scoped verdicts carry plan_id and match on (plan_id, leaf-suffix, new) —
# the numeric index in field is informational. Vendor/platform/capabilities
# verdicts have no plan_id and match on the full field path.
confirmed_plan_triples="[]"
confirmed_global_fields="[]"
if [[ -n "$VALIDATED" ]] && [[ -f "$VALIDATED" ]] && jq empty "$VALIDATED" 2>/dev/null; then
  confirmed_plan_triples=$(jq '[.changes[]? | select(.confirmed == true) | select(.plan_id != null) | {plan_id, field, new}]' "$VALIDATED")
  confirmed_global_fields=$(jq '[.changes[]? | select(.confirmed == true) | select(.plan_id == null) | .field]' "$VALIDATED")
else
  echo "WARNING: Changes detected but no valid verdict — skipping apply"
fi

tmpfile=$(mktemp "${DATA_FILE}.XXXXXX")
trap 'rm -f "$tmpfile"' EXIT

# Merge strategy:
# - All changes (editorial + structural): from proposed only if confirmed
# - Price fields: always from original
# - Protected fields (capabilities): always from original
# - Plan removals: never (conservative)
jq \
  --argjson proposed "$(jq '.proposed' "$FINDINGS")" \
  --argjson diff "$(cat "$DIFF_RESULTS")" \
  --argjson confirmed_plan_triples "$confirmed_plan_triples" \
  --argjson confirmed_global_fields "$confirmed_global_fields" \
  --arg caps_first_pass "$caps_first_pass" \
  --arg bump_date "$BUMP_DATE" \
  '
  . as $original |

  # Strip leading "plans.<idx>." from a field path. Apply matches plans-scoped
  # verdicts on (plan_id, leaf-suffix, new) — the numeric index drifts when
  # proposed/original arrays differ in length, so we route around it.
  def leaf_of($field): $field | sub("^plans\\.[0-9]+\\."; "");

  # Plans-scoped confirmation: validator emitted a {plan_id, field, new} for
  # exactly this plan, leaf, and proposed value, with confirmed:true.
  def is_plan_field_confirmed($pid; $leaf; $new):
    $confirmed_plan_triples
    | any(.plan_id == $pid
          and leaf_of(.field) == $leaf
          and ((.new // null) == ($new // null)));

  # Non-plan-scoped confirmation (vendor.*, platform.*, capabilities.*,
  # verification_override): match on full field path. No plan_id involved.
  def is_global_field_confirmed($field):
    $confirmed_global_fields | index($field) != null;

  # Helper: strip newly-introduced "Annual billing: $X/mo" from notes.
  # Preserves existing annual claims (added by price-update). Prevents
  # tool-update agents from injecting dollar amounts via free text.
  def strip_new_annual($orig; $new):
    if (($orig // "") | test("Annual billing:")) then $new
    elif ($new | test("Annual billing:")) then
      $new | gsub("[; ]*Annual billing: \\$[0-9.,]+/mo[; ]*"; "; ")
           | gsub("^[; ]+|[; ]+$"; "")
    else $new
    end;

  # Merge plans: iterate original plans (with index), overlay from proposed.
  # Each per-plan confirmation check uses the actual plan index so that
  # validator verdicts are scoped per-plan, not picked globally via `first`.
  .plans = [(.plans | to_entries[]) | .key as $idx | .value as $orig |
    ($proposed.plans // [] | map(select(.id == $orig.id)) | first // null) as $prop |
    if $prop == null then $orig  # not in proposed = keep original (no _last_seen bump — agent did not enumerate this plan)
    else
      $orig |
      # Temporal persistence: advance _last_seen_on_page only when the agent marked
      # this plan observed on the page this fetch (proposed._last_seen_on_page ==
      # today). Otherwise keep the existing value so an unobserved plan keeps aging.
      (if $bump_date != "" and (($prop._last_seen_on_page // null) == $bump_date) then ._last_seen_on_page = $bump_date else . end) |
      # Editorial: notes (confirmed only, annual billing claims filtered)
      (if $prop.includes.notes and $prop.includes.notes != ($orig.includes.notes // null) then
        if is_plan_field_confirmed($orig.id; "includes.notes"; $prop.includes.notes) then .includes.notes = strip_new_annual($orig.includes.notes; $prop.includes.notes) else . end
       else . end) |
      (if $prop.includes then
        .includes.premium_requests = $prop.includes.premium_requests |
        .includes.tokens_included = $prop.includes.tokens_included
       else . end) |
      (if $prop.overage and $prop.overage.notes and $prop.overage.notes != ($orig.overage.notes // null) then
        if is_plan_field_confirmed($orig.id; "overage.notes"; $prop.overage.notes) then .overage.notes = $prop.overage.notes else . end
       else . end) |

      # Structural: plan name, category (confirmed only)
      (if $prop.name != $orig.name then
        if is_plan_field_confirmed($orig.id; "name"; $prop.name) then .name = $prop.name else . end
       else . end) |
      (if $prop.category != $orig.category then
        if is_plan_field_confirmed($orig.id; "category"; $prop.category) then .category = $prop.category else . end
       else . end) |

      # Structural: overage unit, mechanism, model (confirmed only)
      (if $prop.overage then
        (if $prop.overage.unit and $prop.overage.unit != ($orig.overage.unit // null) then
          if is_plan_field_confirmed($orig.id; "overage.unit"; $prop.overage.unit) then .overage.unit = $prop.overage.unit else . end
         else . end) |
        (if $prop.overage.mechanism and $prop.overage.mechanism != ($orig.overage.mechanism // null) then
          if is_plan_field_confirmed($orig.id; "overage.mechanism"; $prop.overage.mechanism) then .overage.mechanism = $prop.overage.mechanism else . end
         else . end) |
        (if $prop.overage.model and $prop.overage.model != ($orig.overage.model // null) then
          if is_plan_field_confirmed($orig.id; "overage.model"; $prop.overage.model) then .overage.model = $prop.overage.model else . end
         else . end)
       else . end) |

      # Platform plan flag (structural — confirmed only)
      (if $prop | has("platform_plan") and ($prop.platform_plan != ($orig.platform_plan // null)) then
        if is_plan_field_confirmed($orig.id; "platform_plan"; $prop.platform_plan) then .platform_plan = $prop.platform_plan else . end
       else . end) |

      # Restore price amount from original (price-update scope).
      # Allow base_price nullification (fixed→PAYG) only when confirmed.
      # base_price.{period,per} are plans-scoped — route through plan-id gate.
      (if $prop.base_price == null and $orig.base_price != null then
        ([$diff.changes[] | select(.plan_id == $orig.id) | select(.field | test("base_price\\.(period|per)$"))]) as $bp_changes |
        if ($bp_changes | length > 0)
           and ($bp_changes | all(is_plan_field_confirmed($orig.id; leaf_of(.field); .new)))
        then .base_price = null
        else .base_price = $orig.base_price end
      elif $orig.base_price != null then
        .base_price.amount = ($orig.base_price.amount // null)
      else . end) |
      (if $orig.overage then
        .overage.input_per_million = ($orig.overage.input_per_million // null) |
        .overage.output_per_million = ($orig.overage.output_per_million // null) |
        .overage.price_per_unit = ($orig.overage.price_per_unit // null)
       else . end)
    end
  ] |

  # Vendor metadata (structural — per-field confirmed). Non-plan-scoped, no
  # plan_id involved — match on full field path.
  (reduce ($diff.changes[] | select(.field | startswith("vendor."))) as $c
    (.;
      if is_global_field_confirmed($c.field) then
        ($c.field | ltrimstr("vendor.")) as $key |
        .vendor[$key] = $proposed.vendor[$key]
      else . end
    )
  ) |

  # Verification override (structural — confirmed only)
  (if ($diff.changes | map(select(.field == "verification_override")) | length > 0) then
    if is_global_field_confirmed("verification_override") then
      .verification_override = $proposed.verification_override
    else . end
   else . end) |

  # Platform object (structural — all changes must be confirmed)
  (if ($proposed | has("platform")) and ($diff.changes | map(select(.field | startswith("platform."))) | length > 0) then
    if [$diff.changes[] | select(.field | startswith("platform.")) | .field] | all(is_global_field_confirmed(.)) then
      .platform = $proposed.platform
    else . end
   else . end) |

  # Conditional: restore capabilities from original UNLESS _capabilities_first_pass
  # was set at start of run (captured in $caps_first_pass). When set, apply only
  # validator-confirmed capability changes from proposed.
  (if $caps_first_pass == "true" then
    reduce ($diff.changes[] | select(.field | startswith("capabilities."))) as $c
      (.;
        if is_global_field_confirmed($c.field) then
          ($c.field | ltrimstr("capabilities.")) as $key |
          .capabilities[$key] = $proposed.capabilities[$key]
        else . end
      )
   else
    .capabilities = $original.capabilities
   end)
  ' "$DATA_FILE" > "$tmpfile"

# Add new plans — honor per-field verdicts (Fix 1, 2026-05-24).
# The validator emits per-field rejections at paths like plans.<idx>.<field>.
# We use the idx carried in $DIFF_RESULTS.new_plans (now {id, idx} objects) to
# match those rejections, and null out any sub-field the validator did not
# confirm. Dollar amounts are nulled regardless (price-update's scope).
new_plans_count=$(jq '.new_plans // [] | length' "$DIFF_RESULTS")
if [[ "$new_plans_count" -gt 0 ]]; then
  for i in $(seq 0 $((new_plans_count - 1))); do
    plan_id=$(jq -r ".new_plans[$i].id" "$DIFF_RESULTS")
    plan_idx=$(jq -r ".new_plans[$i].idx" "$DIFF_RESULTS")

    if [[ -z "$VALIDATED" ]] || [[ ! -f "$VALIDATED" ]]; then
      echo "  Skipping new plan (no verdict): $plan_id"
      continue
    fi

    # Plan-level confirmation: validator says this tier exists on the page.
    # Accept any of: field=<plan_id> (legacy), field=plan_id with new=<plan_id>,
    # or plan_id=<plan_id> (current shape — emitted by diff for all plans-scoped
    # changes, so a per-field confirmation on the new plan implies plan-level).
    is_confirmed=$(jq --arg pid "$plan_id" \
      '[.changes[]? | select(.confirmed == true) | select(.field == $pid or (.field == "plan_id" and .new == $pid) or .plan_id == $pid)] | length > 0' "$VALIDATED")
    if [[ "$is_confirmed" != "true" ]]; then
      echo "  Skipping unconfirmed new plan: $plan_id"
      continue
    fi

    # Structural-identity guard (Fix, 2026-07-04; supersedes the 2026-05-31
    # shell-plan guard). Plan-level confirmation alone is not enough — the
    # validator can confirm a plan_id and reject every sub-field, leaving the
    # per-field nullifier (Fix 1, 2026-05-24) to produce an id-only shell
    # (mistral-education, 2026-05-31). And a plan admitted with a null name or
    # category ships as a visible defect: null category drops the plan from
    # every index.html column, null name renders a blank tier label
    # (kiro/augment, 2026-06-14). Require confirmed non-null NAME and CATEGORY
    # before the plan lands; an unconfirmed plan gets re-proposed next cycle.
    identity_confirmed=$(jq --arg pid "$plan_id" --argjson idx "$plan_idx" \
      '[.changes[]?
        | select(.confirmed == true)
        | select(.new != null)
        | select(
            .plan_id == $pid
            or (.plan_id == null and (.field | startswith("plans.\($idx).")))
          )
        | .field | sub("^plans\\.[0-9]+\\."; "")
      ] as $leaves
      | (($leaves | index("name")) != null) and (($leaves | index("category")) != null)' "$VALIDATED")
    if [[ "$identity_confirmed" != "true" ]]; then
      echo "  Skipping plan without confirmed name/category: $plan_id"
      continue
    fi

    # Per-field gate: start with the proposed plan, null out every leaf whose
    # plans.<idx>.<leaf-path> is not confirmed:true in the verdict. Preserve
    # .id (implicitly confirmed by plan-level verdict).
    new_plan=$(jq \
      --arg pid "$plan_id" \
      --argjson idx "$plan_idx" \
      --arg bump_date "$BUMP_DATE" \
      --slurpfile verdict "$VALIDATED" '
      # Filter verdict to entries scoped to this plan first (plan_id match).
      # Within a single plan there is no index collision, so leaf-path membership
      # is sufficient. Tolerate legacy verdict shape (no plan_id) by falling
      # back to the old plans.<idx>.<leaf> path lookup.
      ([$verdict[0].changes[]?
        | select(.confirmed == true)
        | select(.plan_id == $pid)
        | (.field | sub("^plans\\.[0-9]+\\."; ""))]) as $confirmed_leaves |
      ([$verdict[0].changes[]?
        | select(.confirmed == true)
        | select(.plan_id == null)
        | .field]) as $legacy_confirmed_fields |
      def field_confirmed($leaf):
        ($confirmed_leaves | index($leaf)) != null
        or ($legacy_confirmed_fields | index("plans.\($idx).\($leaf)")) != null;

      .proposed.plans[] | select(.id == $pid) |
      . as $orig |
      reduce ([paths(scalars)] | .[]) as $p
        ($orig;
          ($p | map(tostring) | join(".")) as $local_path |
          if $local_path == "id" then .
          elif field_confirmed($local_path) then .
          else setpath($p; null)
          end
        ) |
      # Price fields always nulled (price-update scope) — overrides any verdict
      (if .base_price then .base_price.amount = null else . end) |
      (if .overage then
        .overage.input_per_million = null |
        .overage.output_per_million = null |
        .overage.price_per_unit = null
      else . end) |
      # Initialize _last_seen_on_page so the temporal-persistence clock starts now.
      (if $bump_date != "" then ._last_seen_on_page = $bump_date else . end)
    ' "$FINDINGS")

    if [[ -n "$new_plan" ]] && [[ "$new_plan" != "null" ]]; then
      jq --argjson np "$new_plan" '.plans += [$np]' "$tmpfile" > "${tmpfile}.tmp"
      mv "${tmpfile}.tmp" "$tmpfile"
      echo "  Added new plan: $plan_id (idx=$plan_idx, per-field verdicts honored)"
    fi
  done
fi

# Remove plans flagged as eligible by the temporal-persistence gate (Fix 2,
# 2026-05-24). Validator verdicts are no longer consulted for plan removal —
# the diff script's "absent for ≥ K days" criterion is the only auto-remove
# trigger. plan_removal_pending warnings are surfaced for operator visibility
# but produce no apply-side action.
removal_eligible=$(jq -r '[.warnings[]? | select(.type == "plan_removal_eligible") | .plan_id] | .[]' "$DIFF_RESULTS")
if [[ -n "$removal_eligible" ]]; then
  for plan_id in $removal_eligible; do
    days_absent=$(jq -r --arg pid "$plan_id" \
      '[.warnings[]? | select(.type == "plan_removal_eligible") | select(.plan_id == $pid) | .days_absent] | first // "?"' "$DIFF_RESULTS")
    jq --arg pid "$plan_id" '.plans |= map(select(.id != $pid))' "$tmpfile" > "${tmpfile}.tmp"
    mv "${tmpfile}.tmp" "$tmpfile"
    echo "  Removed plan: $plan_id (absent for ${days_absent} days, ≥ threshold)"
  done
fi

# Surface pending removals (no apply action — operator visibility only)
removal_pending=$(jq -r '[.warnings[]? | select(.type == "plan_removal_pending") | .plan_id] | .[]' "$DIFF_RESULTS")
if [[ -n "$removal_pending" ]]; then
  for plan_id in $removal_pending; do
    days_absent=$(jq -r --arg pid "$plan_id" \
      '[.warnings[]? | select(.type == "plan_removal_pending") | select(.plan_id == $pid) | .days_absent // "n/a"] | first // "?"' "$DIFF_RESULTS")
    echo "  Pending removal (no action): $plan_id (absent for ${days_absent} days, < threshold)"
  done
fi

if diff -q <(jq -S . "$DATA_FILE") <(jq -S . "$tmpfile") >/dev/null 2>&1; then
  echo "No changes applied (all filtered or unconfirmed)"
else
  mv "$tmpfile" "$DATA_FILE"
  trap - EXIT
  echo "Applied changes to $(basename "$DATA_FILE")"
fi
