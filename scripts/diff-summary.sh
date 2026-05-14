#!/usr/bin/env bash
set -euo pipefail

# Print a git-diff-style summary of per-plan changes vs HEAD for the
# given tool slugs. Used at the end of local-tool-update.sh and
# local-price-update.sh to make manual verification easier.
#
# Compares: git show HEAD:data/tools/<slug>.json  vs  data/tools/<slug>.json
# Matches plans by .id (positional reorders are not surfaced as changes).
# Surfaces: per-plan field changes, added plans, removed plans, top-level
# changes (vendor.*, verification_override, platform.*). Capabilities are
# excluded (protected field, never auto-modified).
#
# Usage: ./scripts/diff-summary.sh <slug> [slug...]

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

[[ $# -gt 0 ]] || { echo "Usage: $0 <slug> [slug...]" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }

any=false
out=""

for slug in "$@"; do
  data="data/tools/${slug}.json"
  [[ -f "$data" ]] || continue

  old=$(git show "HEAD:${data}" 2>/dev/null || echo '{}')
  new=$(cat "$data")

  block=$(jq -rn \
    --argjson old "$old" \
    --argjson new "$new" \
    --arg slug "$slug" '
    def flat:
      [paths(scalars) as $p | {key: ($p|map(tostring)|join(".")), value: getpath($p)}]
      | from_entries;

    def diff_obj($o; $n):
      ($o | flat) as $of |
      ($n | flat) as $nf |
      [
        ($of | to_entries[] | select($nf[.key] != .value)
          | {field: .key, old: .value, new: $nf[.key]}),
        ($nf | to_entries[] | select(($of[.key] // null) == null and .value != null)
          | {field: .key, old: null, new: .value})
      ];

    ([$old.plans // [] | .[]? | {key: .id, value: .}] | from_entries) as $oid |
    ([$new.plans // [] | .[]? | {key: .id, value: .}] | from_entries) as $nid |

    [$oid | to_entries[] |
      .key as $id | .value as $o |
      ($nid[$id] // null) as $n |
      if $n == null then {kind: "removed", id: $id}
      else
        diff_obj($o; $n) as $c |
        if ($c | length) > 0 then {kind: "changed", id: $id, changes: $c}
        else empty end
      end
    ] as $existing_diffs |

    [$nid | to_entries[] | select(($oid[.key] // null) == null)
      | {kind: "added", id: .key, plan: .value}] as $new_plan_diffs |

    ($existing_diffs + $new_plan_diffs) as $plan_diffs |

    diff_obj(
      ($old | del(.plans, .capabilities));
      ($new | del(.plans, .capabilities))
    ) as $top |

    if (($plan_diffs | length) == 0) and (($top | length) == 0) then empty
    else
      "\($slug):",
      (if ($top | length) > 0 then
        "  ~ (top-level)",
        ($top[] | "      \(.field):",
                  "        - \(.old | tostring)",
                  "        + \(.new | tostring)")
       else empty end),
      ($plan_diffs[] |
        if .kind == "changed" then
          "  ~ \(.id)",
          (.changes[] | "      \(.field):",
                        "        - \(.old | tostring)",
                        "        + \(.new | tostring)")
        elif .kind == "added" then
          "  + \(.id) (new plan)",
          (.plan | flat | to_entries[]
            | select(.value != null and (.key != "id"))
            | "      \(.key): \(.value | tostring)")
        else
          "  - \(.id) (removed)"
        end
      ),
      ""
    end
    ' 2>/dev/null) || block=""

  if [[ -n "$block" ]]; then
    if [[ -z "$out" ]]; then
      out="$block"
    else
      out="$out

$block"
    fi
    any=true
  fi
done

echo "=== Applied changes (vs HEAD) ==="
echo ""
if [[ "$any" == "true" ]]; then
  echo "$out"
else
  echo "No changes vs HEAD."
fi
