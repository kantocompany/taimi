#!/usr/bin/env bash
# Observation review brief: data changes since the last market update, mapped
# to the observation bullets that mention each tool. A ⚠ line flags a plan
# name a bullet still uses after that plan was removed or renamed.
#
# Market update reads this before its observations review (the agent only
# confirms the claims it chooses to check; the brief tells it what changed),
# and re-runs it with --flags-only afterwards to surface anything unresolved.
#
# Read-only, deterministic (git + jq), always exits 0.
#
# Usage: ./scripts/observations-brief.sh [--flags-only]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 0

flags_only=false
[[ "${1:-}" == "--flags-only" ]] && flags_only=true

base=$(git log -1 --format=%h --grep='^chore: market update' 2>/dev/null) || exit 0
[[ -n "$base" ]] || exit 0
base_date=$(git log -1 --format=%cs "$base")

# Tools present now or at the base (catches adds and archives).
slugs=$( {
  for f in data/tools/*.json; do [[ -f "$f" ]] && basename "$f" .json; done
  git ls-tree --name-only "$base" -- data/tools/ | sed 's|.*/||; s|\.json$||'
} | sort -u)

changes=$(for s in $slugs; do
  old=$(git show "$base:data/tools/$s.json" 2>/dev/null || echo null)
  new=$(cat "data/tools/$s.json" 2>/dev/null || echo null)
  jq -cn --argjson o "$old" --argjson n "$new" --arg s "$s" '
    def by_id($t): [($t.plans // [])[] | {key: .id, value: .}] | from_entries;
    ($n // $o) as $cur | by_id($o) as $op | by_id($n) as $np |
    {
      slug: $s, tool: $cur.name,
      aliases: ([$cur.name, ($cur.vendor.name // "")] | map(split(" ")[] | gsub("[^A-Za-z0-9+.-]"; ""))
                | map(select(length >= 4 and (IN("Code", "Services", "Company", "Inc.") | not))) | unique),
      event: (if $o == null then "tool added" elif $n == null then "tool archived" else null end),
      tool_level: (if $o == null or $n == null then [] else
        [ (if ($o.vendor.name // null) != ($n.vendor.name // null) then "vendor \($o.vendor.name) → \($n.vendor.name)" else empty end),
          (if ($o.platform // null) != ($n.platform // null) then "platform info changed" else empty end) ] end),
      current: [($n.plans // [])[] | .name],
      removed: [$op | to_entries[] | select($np[.key] == null) | .value.name],
      renamed: [$op | to_entries[] | select($np[.key] != null and $np[.key].name != .value.name)
                | {from: .value.name, to: $np[.key].name}],
      added: [$np | to_entries[] | select($op[.key] == null) | .value.name],
      platform: [$np | to_entries[] | select($op[.key] != null
                 and (($op[.key].platform_plan // false) != (.value.platform_plan // false)))
                 | "\(.value.name) → \(.value.platform_plan // false)"],
      prices: [$np | to_entries[] | select($op[.key] != null
               and ($op[.key].base_price.amount // null) != (.value.base_price.amount // null))
               | "\(.value.name) \($op[.key].base_price.amount // "null") → \(.value.base_price.amount // "null")"],
      notes: [$np | to_entries[] | select($op[.key] != null
              and ($op[.key].includes.notes // null) != (.value.includes.notes // null)) | .value.name]
    }
    | select(.event != null or ((.tool_level + .removed + .renamed + .added + .platform + .prices + .notes) | length > 0))'
done | jq -s '.')

jq -rn --argjson ch "$changes" --rawfile obs data/observations.html \
  --arg base "$base" --arg date "$base_date" --argjson flags_only "$flags_only" '
  def lit: gsub("(?<c>[][+*?().^$|{}\\\\])"; "\\\(.c)");
  def mentions($t): any(.aliases[]; . as $a | $t | test("(^|[^A-Za-z0-9])" + ($a | lit) + "($|[^A-Za-z0-9])"));
  def summary: [
      (.event // empty),
      .tool_level[],
      (if (.removed | length) > 0 then "removed \(.removed | join(", "))" else empty end),
      (if (.renamed | length) > 0 then "renamed \([.renamed[] | "\(.from) → \(.to)"] | join(", "))" else empty end),
      (if (.added | length) > 0 then "added \(.added | join(", "))" else empty end),
      (if (.platform | length) > 0 then "platform_plan \(.platform | join(", "))" else empty end),
      (if (.prices | length) > 0 then "price \(.prices | join(", "))" else empty end),
      (if (.notes | length) > 0 then "notes changed: \(.notes | join(", "))" else empty end)
    ] | join("; ");
  def flags($t): . as $c
    | ([.removed[], .renamed[].from] | unique)[] as $nm
    | select(($c.current | index($nm)) == null)
    # Blank out current plan names that contain the old one (Ultra -> Ultra Max)
    # so a bullet already using the new name is not flagged.
    | (reduce ([$c.current[] | select(contains($nm))] | sort_by(-length))[] as $l
        ($t; gsub($l | lit; " "))) as $t2
    | select($t2 | test("(^|[^A-Za-z0-9])" + ($nm | lit) + "($|[^A-Za-z0-9+])"))
    | "⚠ names \"\($nm)\" — no longer a \($c.tool) plan";

  [$obs | scan("<li>(.*?)</li>"; "s")[0] | gsub("<[^>]*>"; "") | gsub("\\s+"; " ") | ltrimstr(" ")] as $bullets
  | [$bullets | to_entries[] | (.key + 1) as $i | .value as $t
      | {i: $i, text: $t, hits: [$ch[] | select(mentions($t))]}] as $rows
  | if $flags_only then
      ($rows[] | .i as $i | .text as $t | .hits[] | flags($t) | "bullet \($i): \(.)")
    else
      "# Observation review brief",
      "",
      "Data changes since the last market update (\($base), \($date)), per observation bullet that mentions the tool. ⚠ = the bullet names a plan that no longer exists for that tool.",
      ( $rows[] | select(.hits | length > 0) | .text as $t |
        "", "## Bullet \(.i): \($t | .[0:90])…",
        (.hits[] | flags($t) | "- \(.)"),
        (.hits[] | "- \(.tool): \(summary)") ),
      ( [$ch[] | . as $c | select([$rows[].hits[].slug] | index($c.slug) | not)] as $other
        | if ($other | length) > 0 then "", "## Changed tools not mentioned in any bullet",
            ($other[] | "- \(.tool): \(summary)") else empty end )
    end'
exit 0
