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

# Temporal persistence bumper (Fix 2, 2026-05-24).
# When the research agent successfully fetched the vendor page, plans it
# enumerated in proposed.plans get their ._last_seen_on_page set to today.
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

# Bump _last_seen_on_page unconditionally for all plans the agent enumerated —
# this must run even on no-change cycles, otherwise plans never get re-stamped
# and would eventually drift into removal-eligibility just because nothing
# changed for them.
if [[ -n "$BUMP_DATE" ]]; then
  jq --arg bump_date "$BUMP_DATE" \
     --argjson proposed_ids "$(jq '[.proposed.plans[]?.id]' "$FINDINGS")" '
    .plans |= map(
      . as $p |
      if ($proposed_ids | index($p.id)) != null
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

# Build confirmed fields from verdict (empty array if no verdict)
confirmed_fields="[]"
if [[ -n "$VALIDATED" ]] && [[ -f "$VALIDATED" ]] && jq empty "$VALIDATED" 2>/dev/null; then
  confirmed_fields=$(jq '[.changes[]? | select(.confirmed == true) | .field]' "$VALIDATED")
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
  --argjson confirmed "$confirmed_fields" \
  --arg caps_first_pass "$caps_first_pass" \
  --arg bump_date "$BUMP_DATE" \
  '
  . as $original |

  # Helper: is this field confirmed by the validation verdict?
  def is_confirmed($field):
    if ($confirmed | length == 0) then false
    else ($confirmed | index($field) != null)
    end;

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
      # Temporal persistence: bump _last_seen_on_page when agent enumerated this plan
      # in proposed.plans and the page fetch was successful (bump_date populated).
      (if $bump_date != "" then ._last_seen_on_page = $bump_date else . end) |
      # Editorial: notes (confirmed only, annual billing claims filtered)
      (if $prop.includes.notes and $prop.includes.notes != ($orig.includes.notes // null) then
        if is_confirmed("plans.\($idx).includes.notes") then .includes.notes = strip_new_annual($orig.includes.notes; $prop.includes.notes) else . end
       else . end) |
      (if $prop.includes then
        .includes.premium_requests = $prop.includes.premium_requests |
        .includes.tokens_included = $prop.includes.tokens_included
       else . end) |
      (if $prop.overage and $prop.overage.notes and $prop.overage.notes != ($orig.overage.notes // null) then
        if is_confirmed("plans.\($idx).overage.notes") then .overage.notes = $prop.overage.notes else . end
       else . end) |

      # Structural: plan name, category (confirmed only)
      (if $prop.name != $orig.name then
        if is_confirmed("plans.\($idx).name") then .name = $prop.name else . end
       else . end) |
      (if $prop.category != $orig.category then
        if is_confirmed("plans.\($idx).category") then .category = $prop.category else . end
       else . end) |

      # Structural: overage unit, mechanism, model (confirmed only)
      (if $prop.overage then
        (if $prop.overage.unit and $prop.overage.unit != ($orig.overage.unit // null) then
          if is_confirmed("plans.\($idx).overage.unit") then .overage.unit = $prop.overage.unit else . end
         else . end) |
        (if $prop.overage.mechanism and $prop.overage.mechanism != ($orig.overage.mechanism // null) then
          if is_confirmed("plans.\($idx).overage.mechanism") then .overage.mechanism = $prop.overage.mechanism else . end
         else . end) |
        (if $prop.overage.model and $prop.overage.model != ($orig.overage.model // null) then
          if is_confirmed("plans.\($idx).overage.model") then .overage.model = $prop.overage.model else . end
         else . end)
       else . end) |

      # Platform plan flag (structural — confirmed only)
      (if $prop | has("platform_plan") and ($prop.platform_plan != ($orig.platform_plan // null)) then
        if is_confirmed("plans.\($idx).platform_plan") then .platform_plan = $prop.platform_plan else . end
       else . end) |

      # Restore price amount from original (price-update scope).
      # Allow base_price nullification (fixed→PAYG) only when confirmed.
      (if $prop.base_price == null and $orig.base_price != null then
        if ([$diff.changes[] | select(.field | test("base_price\\.(period|per)$"))] | length > 0)
           and ([$diff.changes[] | select(.field | test("base_price\\.(period|per)$")) | .field] | all(is_confirmed(.)))
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

  # Vendor metadata (structural — per-field confirmed)
  (reduce ($diff.changes[] | select(.field | startswith("vendor."))) as $c
    (.;
      if is_confirmed($c.field) then
        ($c.field | ltrimstr("vendor.")) as $key |
        .vendor[$key] = $proposed.vendor[$key]
      else . end
    )
  ) |

  # Verification override (structural — confirmed only)
  (if ($diff.changes | map(select(.field == "verification_override")) | length > 0) then
    if is_confirmed("verification_override") then
      .verification_override = $proposed.verification_override
    else . end
   else . end) |

  # Platform object (structural — all changes must be confirmed)
  (if ($proposed | has("platform")) and ($diff.changes | map(select(.field | startswith("platform."))) | length > 0) then
    if [$diff.changes[] | select(.field | startswith("platform.")) | .field] | all(is_confirmed(.)) then
      .platform = $proposed.platform
    else . end
   else . end) |

  # Conditional: restore capabilities from original UNLESS _capabilities_first_pass
  # was set at start of run (captured in $caps_first_pass). When set, apply only
  # validator-confirmed capability changes from proposed.
  (if $caps_first_pass == "true" then
    reduce ($diff.changes[] | select(.field | startswith("capabilities."))) as $c
      (.;
        if is_confirmed($c.field) then
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
    # Accept either field=<plan_id> (legacy) or field=plan_id with new=<plan_id>.
    is_confirmed=$(jq --arg pid "$plan_id" \
      '[.changes[]? | select(.confirmed == true) | select(.field == $pid or (.field == "plan_id" and .new == $pid))] | length > 0' "$VALIDATED")
    if [[ "$is_confirmed" != "true" ]]; then
      echo "  Skipping unconfirmed new plan: $plan_id"
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
      ([$verdict[0].changes[]? | select(.confirmed == true) | .field]) as $confirmed_fields |
      def field_confirmed($f): ($confirmed_fields | index($f)) != null;

      .proposed.plans[] | select(.id == $pid) |
      . as $orig |
      reduce ([paths(scalars)] | .[]) as $p
        ($orig;
          ($p | map(tostring) | join(".")) as $local_path |
          if $local_path == "id" then .
          elif field_confirmed("plans.\($idx).\($local_path)") then .
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
