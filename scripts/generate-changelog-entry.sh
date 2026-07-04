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
  # to API consumers (notes rewording, verification override changes,
  # internal provenance flag clears)
  def strip_editorial:
    walk(if type == "object" then del(.notes, .verification_override, ._notes_first_pass, ._capabilities_first_pass, ._last_seen_on_page, ._pending) else . end);

  def flatten_leaves:
    [paths(scalars) as $p | {key: ($p | map(tostring) | join(".")), value: getpath($p)}]
    | from_entries;

  def diff_lines($o; $n; $prefix):
    ($o | flatten_leaves) as $of |
    ($n | flatten_leaves) as $nf |
    ([$of | to_entries[] | select($nf[.key] != null and $nf[.key] != .value) |
      "\($prefix)\(.key): \(.value) → \($nf[.key])"] ) +
    ([$nf | to_entries[] | select($of[.key] == null) |
      "\($prefix)\(.key): added \(.value)"] ) +
    ([$of | to_entries[] | select($nf[.key] == null) |
      "\($prefix)\(.key): removed"] );

  ($old[0] | strip_editorial) as $o |
  ($new[0] | strip_editorial) as $n |

  # Plans matched by .id (like diff-summary.sh) so mid-array removals and
  # reorders do not misalign every subsequent plan into fake field changes.
  ([$o.plans // [] | .[] | {key: .id, value: .}] | from_entries) as $oid |
  ([$n.plans // [] | .[] | {key: .id, value: .}] | from_entries) as $nid |

  diff_lines(($o | del(.plans)); ($n | del(.plans)); "") as $top |

  ([$oid | to_entries[] | .key as $id |
    select($nid[$id] != null) |
    diff_lines(.value; $nid[$id]; "plans[\($id)].")[]] ) as $changed |

  ([$nid | to_entries[] | select($oid[.key] == null) |
    "plan added: \(.key)\(if .value.name then " (\(.value.name))" else "" end)"] ) as $added |

  ([$oid | to_entries[] | select($nid[.key] == null) |
    "plan removed: \(.key)\(if .value.name then " (\(.value.name))" else "" end)"] ) as $removed |

  ($top + $changed + $added + $removed) | join("; ")
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
