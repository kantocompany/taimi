# Shared by diff-tool-findings.sh, generate-changelog-entry.sh and diff-summary.sh
# (jq -L scripts/lib, include "flatten").
#
# Flatten a tool or plan object to {"dotted.path": leaf}. Leaves are strings,
# numbers and true; false and null are skipped, so false, null and absent mean
# the same — as in apply and CLAUDE.md (a missing platform_plan means
# standalone). Accepted cost: true → false is logged as a removal.
# platform.bundled_with is a set: one sorted value instead of one leaf per index,
# so an insertion is one change (2026-10-21 Codex). A platform that is not an
# object is flattened like any other value.
def flatten_leaves:
  (if (.platform | type) == "object" and (.platform.bundled_with | type) == "array"
   then {"platform.bundled_with": (.platform.bundled_with | unique)} else {} end)
  + ([paths(scalars) as $p
      | select($p[:2] != ["platform", "bundled_with"] or (.platform.bundled_with | type) != "array")
      | {key: ($p | map(tostring) | join(".")), value: getpath($p)}] | from_entries);
