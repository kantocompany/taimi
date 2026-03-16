#!/usr/bin/env bash
# Run price verification for all tools locally.
# Simulates the CI matrix strategy with optional parallelism.
#
# Usage:
#   ./scripts/local-price-update.sh                          # all tools, sequential
#   ./scripts/local-price-update.sh cursor aider              # specific tools only
#   ./scripts/local-price-update.sh -j4                       # all tools, 4 parallel
#   ./scripts/local-price-update.sh --model claude-opus-4-6   # override model
#   ./scripts/local-price-update.sh --max-turns 18 cursor     # override turns
set -euo pipefail

DATE=$(date -u +%Y-%m-%d)
PARALLEL=1
MODEL="claude-sonnet-4-6"
MAX_TURNS=18
SLUGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -j[0-9]*)    PARALLEL="${1#-j}"; shift ;;
    -j)          PARALLEL="$2"; shift 2 ;;
    --model)     MODEL="$2"; shift 2 ;;
    --max-turns) MAX_TURNS="$2"; shift 2 ;;
    *)           SLUGS+=("$1"); shift ;;
  esac
done

if [[ ${#SLUGS[@]} -eq 0 ]]; then
  for f in data/tools/*.json; do
    SLUGS+=("$(basename "$f" .json)")
  done
fi

mkdir -p logs

echo "Price update $DATE — ${#SLUGS[@]} tools, parallelism: $PARALLEL, model: $MODEL, max-turns: $MAX_TURNS"
echo ""

run_agent() {
  local slug="$1"
  local logfile="logs/${slug}.log"
  echo "━━━ $slug ━━━"
  if claude -p "Today is $DATE. Tool: $slug. Read docs/price-update.md and execute." \
    --model "$MODEL" --max-turns "$MAX_TURNS" \
    --allowedTools "Read,Edit,Write,Glob,Grep,WebSearch,WebFetch,Bash(jq *)" \
    2>&1 | tee "$logfile"; then
    echo ""
  else
    echo "  $slug: FAILED (exit $?, see $logfile)"
  fi
}
export DATE MODEL MAX_TURNS

run_agent_quiet() {
  local slug="$1"
  local logfile="logs/${slug}.log"
  echo "→ $slug: starting"
  if claude -p "Today is $DATE. Tool: $slug. Read docs/price-update.md and execute." \
    --model "$MODEL" --max-turns "$MAX_TURNS" \
    --allowedTools "Read,Edit,Write,Glob,Grep,WebSearch,WebFetch,Bash(jq *)" \
    > "$logfile" 2>&1; then
    local status
    status=$(grep -oE '(✅|✏️|⚠️) '"$slug"':.*' "$logfile" | tail -1) || true
    echo "  $slug: ${status:-done}"
  else
    echo "  $slug: FAILED (exit $?, see $logfile)"
  fi
}
export -f run_agent_quiet

if [[ "$PARALLEL" -eq 1 ]]; then
  for slug in "${SLUGS[@]}"; do
    run_agent "$slug"
  done
else
  echo "Parallel mode — output in logs/"
  printf '%s\n' "${SLUGS[@]}" | xargs -P "$PARALLEL" -I{} bash -c 'run_agent_quiet "$@"' _ {}
fi

echo ""

# Generate changelog entries from diffs
echo "Generating changelog entries..."
entries=()
old_snap=$(mktemp -d)
trap 'rm -rf "$old_snap"' EXIT
for slug in "${SLUGS[@]}"; do
  git show HEAD:"data/tools/${slug}.json" 2>/dev/null > "$old_snap/${slug}.json" || echo '{}' > "$old_snap/${slug}.json"
  entry=$(./scripts/generate-changelog-entry.sh \
    "$old_snap/${slug}.json" \
    "data/tools/${slug}.json" \
    "$slug" "$DATE" || true)
  if [[ -n "$entry" ]]; then
    entries+=("$entry")
    echo "  changelog: $slug"
  fi
done
rm -rf "$old_snap"
trap - EXIT
if [[ ${#entries[@]} -gt 0 ]]; then
  new_json=$(printf '%s\n' "${entries[@]}" | jq -s '.')
  tmpfile=$(mktemp "public/v1/changelog.json.XXXXXX")
  trap 'rm -f "$tmpfile"' EXIT
  jq --argjson new "$new_json" \
    '.changes = ($new + .changes) | .meta.updated_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ")) | .meta.version = (now | strftime("%Y-%m-%d"))' \
    public/v1/changelog.json > "$tmpfile"
  mv "$tmpfile" public/v1/changelog.json
  trap - EXIT
  echo "Generated ${#entries[@]} changelog entries"
fi

echo ""
echo "Post-processing..."
ASSEMBLE_DATE="$DATE" ./scripts/assemble.sh
./scripts/generate-index.sh
./scripts/validate.sh
echo ""
echo "Done. Logs in logs/"
