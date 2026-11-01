# Shared by diff-tool-findings.sh, generate-changelog-entry.sh and diff-summary.sh
# (jq -L scripts/lib, include "flatten").
#
# Flatten a tool or plan object to {"dotted.path": leaf}. Leaves are strings,
# numbers and booleans — false included, so true → false is a change, not a
# removal. Null leaves are skipped (null and absent mean the same here).
# platform.bundled_with is a set: one sorted value instead of one leaf per index,
# so an insertion is one change (2026-10-21 Codex). A platform that is not an
# object is flattened like any other value.
def flatten_leaves:
  (if (.platform | type) == "object" and (.platform.bundled_with | type) == "array"
   then {"platform.bundled_with": (.platform.bundled_with | unique)} else {} end)
  + ([paths(type != "object" and type != "array" and . != null) as $p
      | select($p[:2] != ["platform", "bundled_with"] or (.platform.bundled_with | type) != "array")
      | {key: ($p | map(tostring) | join(".")), value: getpath($p)}] | from_entries);
