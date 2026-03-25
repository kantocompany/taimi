#!/usr/bin/env bash
# Generate a changelog entry by diffing two tool JSON files.
# Outputs JSON to stdout if files differ; nothing if identical.
#
# Usage: ./scripts/generate-changelog-entry.sh <old.json> <new.json> <slug> <date>
set -euo pipefail

OLD="$1"
NEW="$2"
SLUG="$3"
DATE="$4"

# Fast path: identical JSON = no entry (normalize to ignore whitespace differences)
if diff -q <(jq -S . "$OLD") <(jq -S . "$NEW") >/dev/null 2>&1; then
  exit 0
fi

SOURCE=$(jq -r '.vendor.pricing_url // "unknown"' "$NEW")

DESCRIPTION=$(jq -rn \
  --slurpfile old "$OLD" \
  --slurpfile new "$NEW" \
  '
  # Strip editorial fields that produce changelog noise but have no value
  # to API consumers (notes rewording, verification override changes)
  def strip_editorial:
    walk(if type == "object" then del(.notes, .verification_override) else . end);

  def flatten_leaves:
    [paths(scalars) as $p | {key: ($p | map(tostring) | join(".")), value: getpath($p)}]
    | from_entries;

  ($old[0] | strip_editorial | flatten_leaves) as $o |
  ($new[0] | strip_editorial | flatten_leaves) as $n |

  ([$o | to_entries[] | select($n[.key] != null and $n[.key] != .value) |
    "\(.key): \(.value) → \($n[.key])"] ) +
  ([$n | to_entries[] | select($o[.key] == null) |
    "\(.key): added \(.value)"] ) +
  ([$o | to_entries[] | select($n[.key] == null) |
    "\(.key): removed"] )
  | join("; ")
  ')

# If only editorial fields changed, skip the entry
if [[ -z "$DESCRIPTION" ]]; then
  exit 0
fi

jq -n \
  --arg date "$DATE" \
  --arg tool "$SLUG" \
  --arg description "$DESCRIPTION" \
  --arg source "$SOURCE" \
  '{
    date: $date,
    tool: $tool,
    type: "pricing_change",
    description: $description,
    details: { source: $source }
  }'
