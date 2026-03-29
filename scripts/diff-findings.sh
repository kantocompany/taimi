#!/usr/bin/env bash
set -euo pipefail

# Compare price-bearing fields between a findings file and current tool data.
# Only compares: base_price.amount, overage rates (input_per_million,
# output_per_million, price_per_unit). Ignores notes, capabilities, and
# all editorial fields — structurally prevents notes drift.
#
# Usage: ./scripts/diff-findings.sh <findings.json> <current-data.json>
# Output: JSON to stdout
# Exit 0: success (check .has_changes). Exit 1: invalid input.

FINDINGS="$1"
CURRENT="$2"

if [[ ! -f "$FINDINGS" ]] || [[ ! -f "$CURRENT" ]]; then
  echo "ERROR: Missing input file" >&2
  exit 1
fi

if ! jq empty "$FINDINGS" 2>/dev/null; then
  echo "ERROR: $FINDINGS is not valid JSON" >&2
  exit 1
fi
if ! jq empty "$CURRENT" 2>/dev/null; then
  echo "ERROR: $CURRENT is not valid JSON" >&2
  exit 1
fi

# If findings status is "unverified", skip all comparison
status=$(jq -r '.status // "unknown"' "$FINDINGS")
if [[ "$status" == "unverified" ]]; then
  slug=$(jq -r '.slug' "$FINDINGS")
  jq -n --arg slug "$slug" \
    '{ slug: $slug, has_changes: false, changes: [], status: "unverified" }'
  exit 0
fi

jq -n \
  --slurpfile findings "$FINDINGS" \
  --slurpfile current "$CURRENT" \
  '
  $findings[0] as $f |
  $current[0] as $c |

  # Build lookup of current plans by id
  ($c.plans | map({key: .id, value: .}) | from_entries) as $current_plans |

  # For a findings plan and its current counterpart, produce
  # a list of {field, old, new} where old != new.
  # Only fields where the finding has a non-null extracted value are compared.
  def price_changes($fp; $cp):
    [
      (if $fp.base_price_amount != null then
        { field: "base_price.amount",
          new:   $fp.base_price_amount,
          old:   (if $cp then ($cp.base_price.amount // null) else null end) }
      else null end),

      (if ($fp.overage // null) != null and $fp.overage.input_per_million != null then
        { field: "overage.input_per_million",
          new:   $fp.overage.input_per_million,
          old:   (if $cp then (($cp.overage // {}).input_per_million // null) else null end) }
      else null end),

      (if ($fp.overage // null) != null and $fp.overage.output_per_million != null then
        { field: "overage.output_per_million",
          new:   $fp.overage.output_per_million,
          old:   (if $cp then (($cp.overage // {}).output_per_million // null) else null end) }
      else null end),

      (if ($fp.overage // null) != null and $fp.overage.price_per_unit != null then
        { field: "overage.price_per_unit",
          new:   $fp.overage.price_per_unit,
          old:   (if $cp then (($cp.overage // {}).price_per_unit // null) else null end) }
      else null end)
    ]
    | map(select(. != null and .old != .new));

  # Compare each findings plan against current data
  [
    $f.plans[] |
    . as $fp |
    ($current_plans[$fp.id] // null) as $cp |
    price_changes($fp; $cp)[] |
    . + { plan_id: $fp.id }
  ] |

  {
    slug:         $f.slug,
    has_changes:  (length > 0),
    changes:      .,
    source_url:   $f.source_url,
    fetch_method: $f.fetch_method,
    status:       $f.status
  }
  '
