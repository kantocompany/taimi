#!/usr/bin/env bash
# Run structural review for all tools locally.
# Four-phase pipeline: research → diff → validate (conditional) → apply.
#
# Usage:
#   ./scripts/local-tool-update.sh                          # all tools, sequential
#   ./scripts/local-tool-update.sh cursor aider              # specific tools only
#   ./scripts/local-tool-update.sh -j4                       # all tools, 4 parallel
#   ./scripts/local-tool-update.sh --model claude-opus-4-6   # override model
#   ./scripts/local-tool-update.sh --max-turns 25 cursor     # override turns
set -euo pipefail

DATE=$(date -u +%Y-%m-%d)
PARALLEL=1
MODEL="claude-sonnet-4-6"
MAX_TURNS=25
VALIDATE_MAX_TURNS=8
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

mkdir -p logs findings diff-results validated

# Clean working files for tools being processed (prevent stale data from previous runs)
for slug in "${SLUGS[@]}"; do
  rm -f "findings/${slug}.json" "diff-results/${slug}.json" "validated/${slug}.json"
done

echo "Tool update $DATE — ${#SLUGS[@]} tools, parallelism: $PARALLEL, model: $MODEL, max-turns: $MAX_TURNS"
echo "Pipeline: research → diff → validate (conditional) → apply"
echo ""

run_pipeline() {
  local slug="$1"
  local logfile="logs/${slug}-tool-update.log"
  echo "━━━ $slug ━━━"

  # Phase 1: Research (no Edit permission)
  echo "  [$slug] Phase 1: Research"
  if claude -p "Today is $DATE. Tool: $slug. Read docs/tool-update.md and execute." \
    --model "$MODEL" --max-turns "$MAX_TURNS" \
    --allowedTools "Read,Write,Glob,Grep,WebSearch,WebFetch,Bash(jq *)" \
    --disallowedTools "Agent,Edit" \
    2>&1 | tee "$logfile"; then
    true
  else
    echo "  $slug: research FAILED (exit $?, see $logfile)"
    echo ""
    return
  fi

  # Safety: restore data file if agent wrote to it despite instructions
  git checkout -- "data/tools/${slug}.json" 2>/dev/null || true

  # Phase 2: Deterministic diff
  echo "  [$slug] Phase 2: Diff"
  if [[ ! -f "findings/${slug}.json" ]]; then
    echo "  $slug: no findings file — agent may have failed"
    echo ""
    return
  fi

  if ! jq empty "findings/${slug}.json" 2>/dev/null; then
    echo "  $slug: findings file is not valid JSON"
    echo ""
    return
  fi

  local diff_result
  diff_result=$(./scripts/diff-tool-findings.sh "findings/${slug}.json" "data/tools/${slug}.json")
  echo "$diff_result" > "diff-results/${slug}.json"
  local has_changes has_structural
  has_changes=$(echo "$diff_result" | jq -r '.has_changes')
  has_structural=$(echo "$diff_result" | jq -r '.has_structural_changes')
  local finding_status
  finding_status=$(echo "$diff_result" | jq -r '.status // "unknown"')

  if [[ "$has_changes" != "true" ]]; then
    if [[ "$finding_status" == "unverified" ]]; then
      echo "  ⚠️ $slug: UNVERIFIED — extraction failed, no comparison"
    else
      echo "  ✅ $slug: reviewed — no structural changes"
    fi
    echo ""
    return
  fi

  echo "  $slug: changes detected (structural=$has_structural):"
  echo "$diff_result" | jq -r '.changes[] | "    \(.category) \(.field): \(.old) → \(.new)"'
  echo "$diff_result" | jq -r '.warnings[]? | "    ⚠️ \(.type): \(.plan_id) — \(.message)"'

  # Phase 3: Validate (conditional — structural changes only)
  local validated_arg=""
  if [[ "$has_structural" == "true" ]]; then
    echo "  [$slug] Phase 3: Validate"
    local validate_logfile="logs/${slug}-tool-validate.log"
    local source_url changes_summary
    source_url=$(echo "$diff_result" | jq -r '.source_url // "unknown"')
    changes_summary=$(echo "$diff_result" | jq -c '.changes')

    if claude -p "$(cat <<PROMPT
Structural review verification for $slug.

A research agent proposes these structural changes:
$changes_summary

Source URL: $source_url

Your task: independently verify each STRUCTURAL change (category "structural").
1. Fetch $source_url
2. For each structural change, confirm the NEW value is supported by the page
3. Write your verdict to validated/${slug}.json with this schema:
{
  "slug": "$slug",
  "changes": [
    { "field": "...", "old": ..., "new": ..., "confirmed": true/false, "evidence": "text from page" }
  ]
}
Skip editorial changes (notes) — those do not need verification.
PROMPT
)" \
      --model "$MODEL" --max-turns "$VALIDATE_MAX_TURNS" \
      --allowedTools "Write,WebSearch,WebFetch" \
      --disallowedTools "Agent,Edit,Read,Bash,Glob,Grep" \
      2>&1 | tee "$validate_logfile"; then
      true
    else
      echo "  $slug: validation FAILED (exit $?, see $validate_logfile)"
    fi

    if [[ -f "validated/${slug}.json" ]] && jq empty "validated/${slug}.json" 2>/dev/null; then
      validated_arg="validated/${slug}.json"
    else
      echo "  $slug: no valid verdict — applying editorial only"
    fi
  else
    echo "  [$slug] Phase 3: Skipped (no structural changes)"
  fi

  # Phase 4: Deterministic apply
  echo "  [$slug] Phase 4: Apply"
  ./scripts/apply-tool-findings.sh \
    "findings/${slug}.json" \
    "diff-results/${slug}.json" \
    "data/tools/${slug}.json" \
    $validated_arg
  echo ""
}
export DATE MODEL MAX_TURNS VALIDATE_MAX_TURNS

run_pipeline_quiet() {
  local slug="$1"
  local logfile="logs/${slug}-tool-update.log"
  local validate_logfile="logs/${slug}-tool-validate.log"
  echo "→ $slug: starting"

  # Phase 1: Research
  if ! claude -p "Today is $DATE. Tool: $slug. Read docs/tool-update.md and execute." \
    --model "$MODEL" --max-turns "$MAX_TURNS" \
    --allowedTools "Read,Write,Glob,Grep,WebSearch,WebFetch,Bash(jq *)" \
    --disallowedTools "Agent,Edit" \
    > "$logfile" 2>&1; then
    echo "  $slug: research FAILED (see $logfile)"; return
  fi
  git checkout -- "data/tools/${slug}.json" 2>/dev/null || true

  # Phase 2: Diff
  if [[ ! -f "findings/${slug}.json" ]] || ! jq empty "findings/${slug}.json" 2>/dev/null; then
    echo "  $slug: no valid findings"; return
  fi
  local diff_result has_changes has_structural
  diff_result=$(./scripts/diff-tool-findings.sh "findings/${slug}.json" "data/tools/${slug}.json")
  echo "$diff_result" > "diff-results/${slug}.json"
  has_changes=$(echo "$diff_result" | jq -r '.has_changes')
  has_structural=$(echo "$diff_result" | jq -r '.has_structural_changes')

  if [[ "$has_changes" != "true" ]]; then
    local status
    status=$(echo "$diff_result" | jq -r '.status // "reviewed"')
    echo "  $slug: $status — no changes"; return
  fi

  # Phase 3: Validate (conditional)
  local validated_arg=""
  if [[ "$has_structural" == "true" ]]; then
    local source_url changes_summary
    source_url=$(echo "$diff_result" | jq -r '.source_url // "unknown"')
    changes_summary=$(echo "$diff_result" | jq -c '.changes')
    if claude -p "Structural review verification for $slug. Changes: $changes_summary. Source: $source_url. Fetch the source URL, verify each structural change, write verdict to validated/${slug}.json with schema: {slug, changes: [{field, old, new, confirmed: bool, evidence}]}" \
      --model "$MODEL" --max-turns "$VALIDATE_MAX_TURNS" \
      --allowedTools "Write,WebSearch,WebFetch" \
      --disallowedTools "Agent,Edit,Read,Bash,Glob,Grep" \
      > "$validate_logfile" 2>&1; then
      if [[ -f "validated/${slug}.json" ]] && jq empty "validated/${slug}.json" 2>/dev/null; then
        validated_arg="validated/${slug}.json"
      fi
    else
      echo "  $slug: validation FAILED (see $validate_logfile)"
    fi
  fi

  # Phase 4: Apply
  ./scripts/apply-tool-findings.sh \
    "findings/${slug}.json" \
    "diff-results/${slug}.json" \
    "data/tools/${slug}.json" \
    $validated_arg
  echo "  $slug: pipeline complete"
}
export -f run_pipeline_quiet

if [[ "$PARALLEL" -eq 1 ]]; then
  for slug in "${SLUGS[@]}"; do
    run_pipeline "$slug"
  done
else
  echo "Parallel mode — output in logs/"
  printf '%s\n' "${SLUGS[@]}" | xargs -P "$PARALLEL" -I{} bash -c 'run_pipeline_quiet "$@"' _ {}
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
echo "Done. Logs in logs/, findings in findings/, verdicts in validated/"
