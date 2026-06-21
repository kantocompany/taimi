#!/usr/bin/env bash
set -euo pipefail

# Market-update scope guard.
#
# Market-update owns the tool SET and the editorial surfaces only:
#   - whole-file add    (scripts/add-tool.sh     -> new untracked data/tools/*.json)
#   - whole-file remove (scripts/archive-tool.sh -> deleted data/tools/*.json)
#   - data/observations.html, public/v1/changelog.json
#
# It must NOT make intra-file field edits to a SURVIVING tool — plan add/remove/
# rename, category, notes, vendor/platform rename, prices, _last_seen_on_page.
# Those are tool-update (structure/terminology) or price-update (amounts) scope.
# See docs/market-update.md "Out of scope" and docs/operational-notes.md
# (2026-06-14, 2026-06-21).
#
# This guard reverts any such modification to HEAD and logs what was dropped so
# the operator can route it to the right pipeline. Added (untracked) and deleted
# tool files are left untouched — they are the legitimate tool-set changes
# market-update is allowed to make.
#
# Deterministic gate (bash + git + jq); mirrors the git-checkout safety net in
# scripts/local-price-update.sh / local-tool-update.sh. Non-fatal: legitimate
# work (new/archived tools, observations, changelog) is preserved, and the
# reverted tree is clean so downstream validate.sh passes naturally.
#
# Usage: ./scripts/guard-market-update.sh   (run after the agent, before assemble.sh)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

command -v git >/dev/null 2>&1 || { echo "ERROR: git is required" >&2; exit 1; }

# Modified-vs-HEAD tracked files under data/tools/ = intra-file edits to surviving
# tools. --diff-filter=M excludes added (untracked, never in git diff) and deleted
# (D) files, so legitimate whole-file add/remove passes through untouched.
violations=$(git diff --name-only --diff-filter=M HEAD -- data/tools/ | grep '\.json$' || true)

if [[ -z "$violations" ]]; then
  echo "✓ market-update scope guard: no out-of-scope tool-file edits"
  exit 0
fi

count=$(printf '%s\n' "$violations" | grep -c . || true)

echo "⚠ market-update scope guard: ${count} out-of-scope tool-file edit(s) detected."
echo "  Market-update may only add or remove whole tool files. Intra-file edits belong to"
echo "  tool-update (structure/terminology) or price-update (amounts). Reverting to HEAD:"
echo ""

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  slug=$(basename "$file" .json)
  echo "── reverted (→ route to tool-update / price-update): $file"
  # Surface what is being dropped BEFORE reverting (reuse diff-summary.sh).
  ./scripts/diff-summary.sh "$slug" 2>/dev/null || git --no-pager diff HEAD -- "$file"
  git checkout HEAD -- "$file"
  echo ""
done <<< "$violations"

echo "⚠ Reverted ${count} edit(s). If any are genuine findings, run the right pipeline:"
echo "    ./scripts/local-tool-update.sh <slug>    # structure / terminology / plans"
echo "    ./scripts/local-price-update.sh <slug>   # prices / overage rates"
exit 0
