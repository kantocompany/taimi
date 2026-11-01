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

# Unverified findings compare nothing: every stored price is reported unchecked.
jq -n \
  --slurpfile findings "$FINDINGS" \
  --slurpfile current "$CURRENT" \
  '
  $findings[0] as $f |
  $current[0] as $c |
  (($f.status // "unknown") == "unverified") as $unverified |

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

  # Overage rate fields with a value on this plan (data) or finding
  def rate_fields:
    [("input_per_million", "output_per_million", "price_per_unit") as $k
      | select((.overage // {})[$k] != null) | "overage.\($k)"];

  # Price fields a data plan stores: base price whenever a base_price object
  # exists (a plan awaiting its price stays flagged), overage rates when set.
  # Contact-sales plans (no base_price, no rates) have nothing to check.
  def stored_fields: (if .base_price != null then ["base_price.amount"] else [] end) + rate_fields;
  def extracted_fields: (if .base_price_amount != null then ["base_price.amount"] else [] end) + rate_fields;

  # Stored price fields with no extracted value this run were never compared,
  # so a clean/verified result says nothing about them. Surface, do not modify.
  # "id" = nothing extracted; "id (fields)" = some fields extracted, these not.
  ([$f.plans[]? | {key: .id, value: (if $unverified then [] else extracted_fields end)}] | from_entries) as $extracted |
  [$c.plans[] | stored_fields as $req | ($req - ($extracted[.id] // [])) as $miss
    | select($miss | length > 0)
    | if $miss == $req then .id else "\(.id) (\($miss | join(", ")))" end] as $uncovered |

  if $unverified then
    { slug: $f.slug, has_changes: false, changes: [], uncovered_plans: $uncovered, status: "unverified" }
  else
    # Compare each findings plan against current data
    [
      $f.plans[] |
      . as $fp |
      ($current_plans[$fp.id] // null) as $cp |
      price_changes($fp; $cp)[] |
      . + { plan_id: $fp.id }
    ] |

    {
      slug:            $f.slug,
      has_changes:     (length > 0),
      changes:         .,
      uncovered_plans: $uncovered,
      source_url:      $f.source_url,
      fetch_method:    $f.fetch_method,
      status:          $f.status
    }
  end
  '
