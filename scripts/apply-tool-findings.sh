#!/usr/bin/env bash
set -euo pipefail

# Apply tool-update changes to a data file.
# Merges proposed JSON but preserves price fields, capabilities, and benchmarks.
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

has_changes=$(jq -r '.has_changes' "$DIFF_RESULTS")
if [[ "$has_changes" != "true" ]]; then
  echo "No changes to apply"
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
# - Protected fields (capabilities, benchmarks): always from original
# - Plan removals: never (conservative)
jq \
  --argjson proposed "$(jq '.proposed' "$FINDINGS")" \
  --argjson diff "$(cat "$DIFF_RESULTS")" \
  --argjson confirmed "$confirmed_fields" \
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

  # Merge plans: iterate original plans, overlay from proposed
  .plans = [.plans[] | . as $orig |
    ($proposed.plans // [] | map(select(.id == $orig.id)) | first // null) as $prop |
    if $prop == null then $orig  # not in proposed = keep original
    else
      $orig |
      # Editorial: notes (confirmed only, annual billing claims filtered)
      (if $prop.includes.notes and $prop.includes.notes != ($orig.includes.notes // null) then
        if is_confirmed($diff.changes | map(select(.field | endswith(".includes.notes"))) | first | .field // "") then .includes.notes = strip_new_annual($orig.includes.notes; $prop.includes.notes) else . end
       else . end) |
      (if $prop.includes then
        .includes.premium_requests = $prop.includes.premium_requests |
        .includes.tokens_included = $prop.includes.tokens_included
       else . end) |
      (if $prop.overage and $prop.overage.notes and $prop.overage.notes != ($orig.overage.notes // null) then
        if is_confirmed($diff.changes | map(select(.field | endswith(".overage.notes"))) | first | .field // "") then .overage.notes = $prop.overage.notes else . end
       else . end) |

      # Structural: plan name, category (confirmed only)
      (if $prop.name != $orig.name and ($diff.changes | map(select(.field | endswith(".name") and (. != "vendor.name"))) | length > 0) then
        if is_confirmed($diff.changes | map(select(.new == $prop.name)) | first | .field // "") then .name = $prop.name else . end
       else . end) |
      (if $prop.category != $orig.category then
        if is_confirmed($diff.changes | map(select(.new == $prop.category)) | first | .field // "") then .category = $prop.category else . end
       else . end) |

      # Structural: overage unit, mechanism, model (confirmed only)
      (if $prop.overage then
        (if $prop.overage.unit and $prop.overage.unit != ($orig.overage.unit // null) then
          if is_confirmed($diff.changes | map(select(.field | endswith(".unit"))) | first | .field // "") then .overage.unit = $prop.overage.unit else . end
         else . end) |
        (if $prop.overage.mechanism and $prop.overage.mechanism != ($orig.overage.mechanism // null) then
          if is_confirmed($diff.changes | map(select(.field | endswith(".mechanism"))) | first | .field // "") then .overage.mechanism = $prop.overage.mechanism else . end
         else . end) |
        (if $prop.overage.model and $prop.overage.model != ($orig.overage.model // null) then
          if is_confirmed($diff.changes | map(select(.field | endswith(".model"))) | first | .field // "") then .overage.model = $prop.overage.model else . end
         else . end)
       else . end) |

      # Platform plan flag (structural — confirmed only)
      (if $prop | has("platform_plan") and ($prop.platform_plan != ($orig.platform_plan // null)) then
        if is_confirmed($diff.changes | map(select(.field | endswith(".platform_plan"))) | first | .field // "") then .platform_plan = $prop.platform_plan else . end
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

  # ALWAYS restore protected fields from original
  .capabilities = $original.capabilities |
  .benchmarks = $original.benchmarks
  ' "$DATA_FILE" > "$tmpfile"

# Add new plans if confirmed
new_plans=$(jq -r '.new_plans // [] | .[]' "$DIFF_RESULTS")
if [[ -n "$new_plans" ]]; then
  for plan_id in $new_plans; do
    # New plans need confirmation
    if [[ -n "$VALIDATED" ]] && [[ -f "$VALIDATED" ]]; then
      is_confirmed=$(jq --arg pid "$plan_id" \
        '[.changes[]? | select(.confirmed == true) | select((.field == $pid) or (.field | split(".") | any(. == $pid)) or (.new == $pid))] | length > 0' "$VALIDATED")
      if [[ "$is_confirmed" != "true" ]]; then
        echo "  Skipping unconfirmed new plan: $plan_id"
        continue
      fi
    else
      echo "  Skipping new plan (no verdict): $plan_id"
      continue
    fi
    # Add plan structure but null out price fields — price-update fills them in
    new_plan=$(jq --arg pid "$plan_id" '
      .proposed.plans[] | select(.id == $pid) |
      (if .base_price then .base_price.amount = null else . end) |
      (if .overage then
        .overage.input_per_million = null |
        .overage.output_per_million = null |
        .overage.price_per_unit = null
      else . end)
    ' "$FINDINGS")
    if [[ -n "$new_plan" ]]; then
      jq --argjson np "$new_plan" '.plans += [$np]' "$tmpfile" > "${tmpfile}.tmp"
      mv "${tmpfile}.tmp" "$tmpfile"
      echo "  Added new plan: $plan_id"
    fi
  done
fi

# Remove confirmed plans
removed_plans=$(jq -r '[.warnings[]? | select(.type == "plan_removal") | .plan_id] | .[]' "$DIFF_RESULTS")
if [[ -n "$removed_plans" ]]; then
  for plan_id in $removed_plans; do
    if [[ -n "$VALIDATED" ]] && [[ -f "$VALIDATED" ]]; then
      is_confirmed=$(jq --arg pid "$plan_id" \
        '[.changes[]? | select(.confirmed == true) | select(.field == ("remove:" + $pid))] | length > 0' "$VALIDATED")
      if [[ "$is_confirmed" == "true" ]]; then
        jq --arg pid "$plan_id" '.plans |= map(select(.id != $pid))' "$tmpfile" > "${tmpfile}.tmp"
        mv "${tmpfile}.tmp" "$tmpfile"
        echo "  Removed plan: $plan_id"
      else
        echo "  Skipping unconfirmed plan removal: $plan_id"
      fi
    fi
  done
fi

if diff -q <(jq -S . "$DATA_FILE") <(jq -S . "$tmpfile") >/dev/null 2>&1; then
  echo "No changes applied (all filtered or unconfirmed)"
else
  mv "$tmpfile" "$DATA_FILE"
  trap - EXIT
  echo "Applied changes to $(basename "$DATA_FILE")"
fi
