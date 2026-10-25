#!/usr/bin/env bash
# Run market update locally. Simulates the CI market-update workflow.
#
# Usage:
#   ./scripts/local-market-update.sh                          # defaults
#   ./scripts/local-market-update.sh --model claude-opus-5   # override model
#   ./scripts/local-market-update.sh --max-turns 40            # override turns
set -euo pipefail

DATE=$(date -u +%Y-%m-%d)
MODEL="claude-sonnet-5-5"
MAX_TURNS=45

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)     MODEL="$2"; shift 2 ;;
    --max-turns) MAX_TURNS="$2"; shift 2 ;;
    *)           echo "Unknown option: $1"; exit 1 ;;
  esac
done

LOGFILE="logs/market-update-${DATE}.log"
mkdir -p logs

echo "Market update $DATE — model: $MODEL, max-turns: $MAX_TURNS"
echo "Log: $LOGFILE"
echo ""

# Deterministic brief for the observations review: data changes since the last
# market update, per bullet, with ⚠ flags for plan names that no longer exist.
mkdir -p fetched
./scripts/observations-brief.sh > fetched/observations-brief.md
echo "Observations brief: fetched/observations-brief.md ($(grep -c '^- ⚠' fetched/observations-brief.md || true) flag(s))"
echo ""

claude -p "Today is $DATE. Read docs/market-update.md and execute. When you add or flesh out a tool, set every plan's _last_seen_on_page to $DATE; do not restate values that live in structured fields (overage rates, premium_requests counts) in plan notes — validate.sh will fail the build; and preserve any existing _pending markers unchanged. Data changes since the last market update, mapped to observation bullets: fetched/observations-brief.md." \
  --model "$MODEL" --max-turns "$MAX_TURNS" --verbose \
  --output-format stream-json \
  --allowedTools "Read,Edit,Write,Glob,Grep,WebSearch,WebFetch,Bash(jq *),Bash(ls *),Bash(bash scripts/*),Bash(bash ./scripts/*)" \
  --disallowedTools "Bash(rm *),Bash(curl *),Bash(wget *),Bash(npm *),Bash(pip *),Bash(sudo *)" \
  2>&1 | tee "$LOGFILE"

echo ""
echo "Agent complete. Enforcing market-update scope..."
# Revert any intra-file edit to a surviving tool — that is tool-update / price-update
# scope. Whole-file add/remove (the tool-set changes market-update owns) pass through.
./scripts/guard-market-update.sh

echo ""
echo "Building..."
ASSEMBLE_DATE="$DATE" ./scripts/assemble.sh
./scripts/generate-index.sh
./scripts/validate.sh
echo ""
# Re-check the agent-edited observations against the same brief (non-fatal).
flags=$(./scripts/observations-brief.sh --flags-only)
if [[ -n "$flags" ]]; then
  echo "⚠ Unresolved observation flags (review before committing):"
  echo "$flags"
else
  echo "✓ No unresolved observation flags"
fi
echo ""
echo "Done."
