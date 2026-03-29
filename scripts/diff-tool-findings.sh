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

  # Protected fields — never auto-modified
  def is_protected_field:
    . as $key |
    ($key | startswith("capabilities.")) or
    ($key | startswith("benchmarks."));

  # Structural fields — verifiable claims, trigger validation
  def is_structural_field:
    . as $key |
    ($key | test("^vendor\\.")) or
    ($key | test("\\.name$")) or
    ($key | test("\\.category$")) or
    ($key | test("overage\\.unit$")) or
    ($key | test("overage\\.mechanism$")) or
    ($key | test("overage\\.model$")) or
    ($key | test("^verification_override$")) or
    ($key | test("\\.platform")) or
    ($key | test("^platform\\."));

  # Flatten JSON to key-value pairs (leaf nodes only)
  def flatten_leaves:
    [paths(scalars) as $p | {key: ($p | map(tostring) | join(".")), value: getpath($p)}]
    | from_entries;

  # Strip price, protected, and meta fields before comparison
  def strip_excluded:
    del(.capabilities, .benchmarks) |
    walk(if type == "object" then
      del(.amount) |
      (if has("input_per_million") then del(.input_per_million) else . end) |
      (if has("output_per_million") then del(.output_per_million) else . end) |
      (if has("price_per_unit") then del(.price_per_unit) else . end)
    else . end);

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

  # Warnings for plan removals
  [$removed_plans[] | {type: "plan_removal", plan_id: ., message: "Plan missing from proposed — not auto-removed"}] as $warnings |

  # New plan warnings
  [$new_plans[] | {type: "plan_addition", plan_id: ., message: "New plan proposed — requires validation"}] as $new_plan_warnings |

  ($changes | map(select(.category == "structural")) | length > 0) as $has_structural |
  ($changes | length > 0 or ($new_plans | length > 0)) as $has_changes |

  {
    slug: $slug,
    has_changes: $has_changes,
    has_structural_changes: ($has_structural or ($new_plans | length > 0)),
    source_url: $source_url,
    fetch_method: $fetch_method,
    status: (if $has_changes then "changes_found" else "reviewed" end),
    changes: $changes,
    new_plans: $new_plans,
    warnings: ($warnings + $new_plan_warnings)
  }
  '
