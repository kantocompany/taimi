#!/usr/bin/env bash
set -euo pipefail

# Apply validated price changes to a tool data file.
# Only applies changes where confirmed == true.
# Modifies the data file in-place via jq.
#
# Usage: ./scripts/apply-findings.sh <validated.json> <data-file.json>
# Exit 0: success (changes applied or nothing confirmed).
# Exit 1: invalid input.

VALIDATED="$1"
DATA_FILE="$2"

if [[ ! -f "$VALIDATED" ]] || [[ ! -f "$DATA_FILE" ]]; then
  echo "ERROR: Missing input file" >&2
  exit 1
fi

if ! jq empty "$VALIDATED" 2>/dev/null; then
  echo "ERROR: $VALIDATED is not valid JSON" >&2
  exit 1
fi

# Count confirmed changes
confirmed=$(jq '[.changes[] | select(.confirmed == true)] | length' "$VALIDATED")

if [[ "$confirmed" -eq 0 ]]; then
  echo "No confirmed changes to apply"
  exit 0
fi

# Apply all confirmed changes in a single jq pass
tmpfile=$(mktemp "${DATA_FILE}.XXXXXX")
trap 'rm -f "$tmpfile"' EXIT

jq --argjson validated "$(cat "$VALIDATED")" '
  # Filter to confirmed changes
  ($validated.changes | map(select(.confirmed == true))) as $confirmed |

  # Apply each change via reduce
  reduce $confirmed[] as $c (.;
    .plans |= map(
      if .id == $c.plan_id then
        if $c.field == "base_price.amount" then
          .base_price.amount = $c.new
        elif $c.field == "overage.input_per_million" then
          .overage.input_per_million = $c.new
        elif $c.field == "overage.output_per_million" then
          .overage.output_per_million = $c.new
        elif $c.field == "overage.price_per_unit" then
          .overage.price_per_unit = $c.new
        else .
        end
      else .
      end
    )
  )
' "$DATA_FILE" > "$tmpfile"

if diff -q <(jq -S . "$DATA_FILE") <(jq -S . "$tmpfile") >/dev/null 2>&1; then
  echo "No changes applied (plan IDs not found in data)"
else
  mv "$tmpfile" "$DATA_FILE"
  trap - EXIT
  echo "Applied confirmed change(s) to $(basename "$DATA_FILE")"
fi
