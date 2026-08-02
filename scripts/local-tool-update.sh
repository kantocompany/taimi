#!/usr/bin/env bash
# Run structural review for all tools locally.
# Four-phase pipeline: research → diff → validate (conditional) → apply.
#
# Usage:
#   ./scripts/local-tool-update.sh                          # all tools, sequential
#   ./scripts/local-tool-update.sh cursor aider              # specific tools only
#   ./scripts/local-tool-update.sh -j4                       # all tools, 4 parallel
#   ./scripts/local-tool-update.sh --model claude-opus-5   # override model
#   ./scripts/local-tool-update.sh --research-max-turns 25 cursor  # override research turns
#   ./scripts/local-tool-update.sh --validate-max-turns 4         # override validation turns
set -euo pipefail

DATE=$(date -u +%Y-%m-%d)
PARALLEL=1
MODEL="claude-sonnet-5"
RESEARCH_MAX_TURNS=25
VALIDATE_MAX_TURNS=20
SLUGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -j[0-9]*)    PARALLEL="${1#-j}"; shift ;;
    -j)          PARALLEL="$2"; shift 2 ;;
    --model)     MODEL="$2"; shift 2 ;;
    --research-max-turns) RESEARCH_MAX_TURNS="$2"; shift 2 ;;
    --validate-max-turns) VALIDATE_MAX_TURNS="$2"; shift 2 ;;
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

echo "Tool update $DATE — ${#SLUGS[@]} tools, parallelism: $PARALLEL, model: $MODEL, research-max-turns: $RESEARCH_MAX_TURNS, validate-max-turns: $VALIDATE_MAX_TURNS"
echo "Pipeline: research → diff → validate (conditional) → apply"
echo ""

run_pipeline() {
  local slug="$1"
  local logfile="logs/${slug}-tool-update.log"
  echo "━━━ $slug ━━━"

  # Dirty-tree guard: the post-research safety checkout below reverts the data
  # file to HEAD, silently wiping uncommitted operator edits (2026-05-17
  # incident). Commit or stash before re-running this slug.
  if [[ -n "$(git status --porcelain -- "data/tools/${slug}.json")" ]]; then
    echo "  $slug: SKIPPED — uncommitted changes on data/tools/${slug}.json; commit or stash operator edits before running tool-update"
    echo ""
    return
  fi

  # Phase 1: Research (no Edit permission)
  echo "  [$slug] Phase 1: Research"
  if claude -p "Today is $DATE. Tool: $slug. Read docs/tool-update.md and execute. When you write proposed.plans[], set each plan's _last_seen_on_page to $DATE ONLY for plans you directly observed on the vendor page this fetch; for any plan you list from prior knowledge or the existing data file but did not see on the page this fetch, copy its existing _last_seen_on_page value unchanged." \
    --model "$MODEL" --max-turns "$RESEARCH_MAX_TURNS" \
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
      # Still invoke apply: even with zero changes, the temporal-persistence
      # bumper must run for every plan the agent successfully enumerated.
      # Apply short-circuits internally once the bumper completes.
      ./scripts/apply-tool-findings.sh \
        "findings/${slug}.json" \
        "diff-results/${slug}.json" \
        "data/tools/${slug}.json"
    fi
    echo ""
    return
  fi

  echo "  $slug: changes detected (structural=$has_structural):"
  echo "$diff_result" | jq -r '.changes[] | "    \(.category) \(.field): \(.old) → \(.new)"'
  echo "$diff_result" | jq -r '.warnings[]? | "    ⚠️ \(.type): \(.plan_id) — \(.message)"'

  # Phase 3: Validate
  echo "  [$slug] Phase 3: Validate"
  local validate_logfile="logs/${slug}-tool-validate.log"
  local validated_arg=""
  local source_url changes_summary
  source_url=$(echo "$diff_result" | jq -r '.source_url // "unknown"')
  changes_summary=$(echo "$diff_result" | jq -c '{changes, new_plans: [(.new_plans // [])[] | .id]}')

  local vprompt=$(cat <<PROMPT
Review verification for $slug.

A research agent proposes these changes:
$changes_summary

Source URL: $source_url
If a direct fetch of the source URL returns partial or script-only content, retry it once through the rendering proxy (prepend https://r.jina.ai/ to the URL) before concluding any claim is absent.

Your task: independently verify each change.
IMPORTANT: Verify ONLY the specific changes listed above. Do not check other fields or report changes you notice independently on the page.

Special rule: any change asserting that a model, plan, or feature is "removed", "unavailable", "deprecated", or "no longer offered" requires a quoted exclusion statement from the page (e.g., "available on Pro and above", "Enterprise only", or an explicit deprecation notice). Absence-of-listing alone is not evidence — mark confirmed: false in that case. The same standard applies in the other direction: if the OLD notes value contains a date or temporal qualifier (e.g., "paused 2026-04-20", "through 2026-05-31", "(beta)") and the NEW value drops it, require a quoted vendor-page statement that the original condition no longer holds. Different wording covering a different event is not evidence of state reversal — mark confirmed: false. The same standard also applies to operator-curated transparency markers in notes (uppercase-prefixed labels like "UNVERIFIED_OVERAGE:", "UNVERIFIED:"): they signal a tracked data gap, not internal annotation. Their removal requires quoted vendor-page evidence the underlying gap is resolved — mark confirmed: false otherwise. Exception for dated dollar citations: when the OLD value contains a dated dollar amount from this tool's pricing page (e.g., "\$3.50 ... 2026-03-24") and the cited rate cannot be reproduced on today's vendor page fetch, mark confirmed: true — inability to find the cited rate IS the state-reversal evidence for these time-stamped page claims.

Symmetry rule: any change adding a feature or capability to a single plan's notes requires scanning the rest of the vendor page (comparison table including ✓/✕ rows, headline cards, feature lists) for the same feature on sibling plans. If the feature appears on the target plan AND ≥1 sibling plan WITHOUT exclusion markers (✕, dash, "not available", greyed cells, or "Enterprise only" wording), mark confirmed: false with evidence — the feature is a tool-wide capability rather than a plan differentiator. This permits scanning the vendor page for cross-plan presence of the specific feature being added, and only that feature; it does not authorize verification of other unrelated fields.

New-plan rule: any change introducing a new plan ID requires a quoted vendor-page tier header, pricing card, or named tier row in a pricing/comparison table (e.g., "Plus — \$20/month", a tile labeled with the plan name, or a comparison-table row whose label is the plan name). Feature mentions in marketing copy, comparison-table feature rows, or sub-bullets are not sufficient evidence — they may describe features within an existing plan rather than constituting a new plan tier. If you cannot quote a tier header, pricing card, or tier row, mark confirmed: false.

Plan-boundary rule: a new plan ID whose evidence describes it as a discount on an existing tier (e.g., "Mistral Pro for \$5.99/month", "students get Pro for \$X", "OSS maintainers get free Team", any wording of the form "<existing-plan-name> for \$Y") is an eligibility discount on that tier, not a separate plan — mark confirmed: false for plan_id and every sub-field of the new plan. Discount eligibility belongs in the qualifying plan's includes.notes, not as a separate plan object. This applies even when the discount has its own pricing card or named heading — the discriminator is whether the card grants access to an existing tier vs. a distinct tier with its own feature set.

1. Fetch $source_url
2. For each field change, confirm the NEW value is supported by the page
3. For each new plan ID, verify the plan exists on the vendor page
4. Write your verdict to validated/${slug}.json with this schema:
{
  "slug": "$slug",
  "changes": [
    { "plan_id": "<copy verbatim from input change if present>", "field": "...", "old": ..., "new": ..., "confirmed": true/false, "evidence": "text from page" },
    { "field": "<new_plan_id>", "confirmed": true/false, "evidence": "plan exists on page" }
  ]
}

If the change you are reviewing has a "plan_id" key, copy it verbatim into your verdict entry. If it does not (vendor.*, platform.*, capabilities.*, verification_override changes), omit the plan_id key — do not invent one.
PROMPT
)
  # Validate with a single auto-retry (see local-price-update.sh): a max-turns
  # death writes no verdict and fails closed, silently holding a likely-correct
  # change. The raised --max-turns budget is the primary fix; retry the backstop.
  local vattempt
  for vattempt in 1 2; do
    claude -p "$vprompt" \
      --model "$MODEL" --max-turns "$VALIDATE_MAX_TURNS" \
      --allowedTools "Write,WebSearch,WebFetch" \
      --disallowedTools "Agent,Edit,Read,Bash,Glob,Grep" \
      2>&1 | tee "$validate_logfile" || true
    if [[ -f "validated/${slug}.json" ]] && jq empty "validated/${slug}.json" 2>/dev/null; then
      break
    fi
    if [[ "$vattempt" -eq 1 ]]; then
      echo "  $slug: no verdict after validate (possible max-turns) — retrying once"
    else
      echo "  $slug: validation incomplete after retry (see $validate_logfile)"
    fi
  done

  if [[ -f "validated/${slug}.json" ]] && jq empty "validated/${slug}.json" 2>/dev/null; then
    validated_arg="validated/${slug}.json"
  else
    echo "  $slug: no valid verdict — skipping apply"
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
export DATE MODEL RESEARCH_MAX_TURNS VALIDATE_MAX_TURNS

run_pipeline_quiet() {
  local slug="$1"
  local logfile="logs/${slug}-tool-update.log"
  local validate_logfile="logs/${slug}-tool-validate.log"
  echo "→ $slug: starting"

  # Dirty-tree guard: the post-research safety checkout below reverts the data
  # file to HEAD, silently wiping uncommitted operator edits (2026-05-17
  # incident). Commit or stash before re-running this slug.
  if [[ -n "$(git status --porcelain -- "data/tools/${slug}.json")" ]]; then
    echo "  $slug: SKIPPED — uncommitted changes on data/tools/${slug}.json; commit or stash operator edits first"
    return
  fi

  # Phase 1: Research
  if ! claude -p "Today is $DATE. Tool: $slug. Read docs/tool-update.md and execute. When you write proposed.plans[], set each plan's _last_seen_on_page to $DATE ONLY for plans you directly observed on the vendor page this fetch; for any plan you list from prior knowledge or the existing data file but did not see on the page this fetch, copy its existing _last_seen_on_page value unchanged." \
    --model "$MODEL" --max-turns "$RESEARCH_MAX_TURNS" \
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
    # Even with zero changes, invoke apply so the temporal-persistence bumper
    # runs for every plan the agent successfully enumerated.
    if [[ "$status" != "unverified" ]]; then
      ./scripts/apply-tool-findings.sh \
        "findings/${slug}.json" \
        "diff-results/${slug}.json" \
        "data/tools/${slug}.json" > /dev/null
    fi
    echo "  $slug: $status — no changes (last_seen bumped)"; return
  fi

  # Phase 3: Validate
  local validated_arg=""
  local source_url changes_summary
  source_url=$(echo "$diff_result" | jq -r '.source_url // "unknown"')
  changes_summary=$(echo "$diff_result" | jq -c '{changes, new_plans: [(.new_plans // [])[] | .id]}')
  local vprompt="Review verification for $slug. Changes: $changes_summary. Source: $source_url. Fetch the source URL, verify each change. If a direct fetch of the source URL returns partial or script-only content, retry it once through the rendering proxy (prepend https://r.jina.ai/ to the URL) before concluding any claim is absent. Verify ONLY the listed changes — do not check or report other fields. Special rule: 'removed/unavailable/deprecated' claims need a quoted exclusion from the page; drops of dated/temporal claims from existing notes need a quoted state-reversal from the page; drops of UPPERCASE_PREFIX: operator markers (UNVERIFIED_OVERAGE:, UNVERIFIED:) need quoted evidence the underlying gap is resolved; absence-of-listing alone → confirmed: false. Exception for dated dollar citations from this tool's page: confirmed: true when cited rate cannot be reproduced on today's page. Symmetry rule: per-plan notes additions where the same feature shows ✓/included on sibling plans without exclusion markers → confirmed: false (tool-wide, not plan-specific). New-plan rule: new plan IDs need a quoted tier header, pricing card, or named tier row from the page; feature mentions don't count → confirmed: false. Plan-boundary rule: a new plan ID whose evidence describes it as a discount on an existing tier (e.g., 'Pro for \$5.99/month', 'students get Pro for \$X', any '<existing-plan> for \$Y' wording) is an eligibility discount on that tier, not a separate plan → confirmed: false for plan_id and every sub-field. For new plan IDs, confirm they exist on the page. Write verdict to validated/${slug}.json with schema: {slug, changes: [{plan_id?, field, old, new, confirmed: bool, evidence}]}. Copy plan_id verbatim from input change when present; omit when input change has no plan_id (vendor/platform/capabilities/verification_override). For new plans use field=plan_id."
  local vattempt
  for vattempt in 1 2; do
    claude -p "$vprompt" \
      --model "$MODEL" --max-turns "$VALIDATE_MAX_TURNS" \
      --allowedTools "Write,WebSearch,WebFetch" \
      --disallowedTools "Agent,Edit,Read,Bash,Glob,Grep" \
      > "$validate_logfile" 2>&1 || true
    if [[ -f "validated/${slug}.json" ]] && jq empty "validated/${slug}.json" 2>/dev/null; then
      validated_arg="validated/${slug}.json"
      break
    fi
    [[ "$vattempt" -eq 1 ]] && echo "  $slug: no verdict after validate (possible max-turns) — retrying once"
  done

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
./scripts/diff-summary.sh "${SLUGS[@]}"
echo ""
echo "Done. Logs in logs/, findings in findings/, verdicts in validated/"
