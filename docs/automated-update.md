# Automated Updates

## Overview

Updates run via three GitHub Actions workflows using Claude Code. All create PRs for human review — none touch main directly.

| Workflow | Runbook | Schedule | Scope |
|----------|---------|----------|-------|
| `price-update.yml` | `docs/price-update.md` | Daily 05:00 UTC | Price verification (matrix: one agent per tool) |
| `tool-update.yml` | `docs/tool-update.md` | Weekly Wednesday 03:00 UTC | Structural review (matrix: one agent per tool) |
| `market-update.yml` | `docs/market-update.md` | Weekly Sunday 02:00 UTC | Market scan, health checks, observations review |

The three workflows have **zero overlap**. Price verification checks amounts. Tool update checks structure (plans, categories, notes). Market update scans for new tools and editorial quality.

## How it works

### Price update (daily) — four-phase matrix architecture

1. **Setup job**: cron fires at 05:00 UTC (or manual dispatch). Checks for open PR, discovers tool slugs from `data/tools/*.json`
2. **Verify jobs** (parallel, one per tool): four-phase pipeline per tool:
   - **Phase 1 — Research**: Claude Code agent fetches vendor pricing page and writes findings to `findings/{slug}.json`. Agent has no Edit permission — cannot modify data files.
   - **Phase 2 — Diff**: deterministic jq script (`diff-findings.sh`) compares findings against `data/tools/{slug}.json`. Only price-bearing fields (base_price.amount, overage rates) are compared. Notes, capabilities, and editorial fields are structurally ignored.
   - **Phase 3 — Validate** (conditional): runs only when Phase 2 detects price changes. A clean-slate Claude Code agent independently fetches the vendor page and verifies each specific change. No access to the research agent's reasoning, the runbook, or any repo files.
   - **Phase 4 — Apply**: deterministic jq script (`apply-findings.sh`) applies only confirmed changes to `data/tools/{slug}.json`.
3. **Finalize job**: downloads artifacts from all verify jobs, generates changelog entries from diffs, runs `assemble.sh` + `generate-index.sh` + `validate.sh`, commits `data/` + `public/`, opens PR
4. `validate.yml` runs on the PR as a status check
5. Human reviews and merges

### Tool update (weekly) — matrix architecture

1. **Setup job**: cron fires at 03:00 UTC Wednesday (or manual dispatch). Checks for open PR, discovers tool slugs
2. **Review jobs** (parallel, one per tool): each runs Claude Code agent scoped to one vendor. Fetches pricing page and compares full plan structure against `data/tools/{slug}.json`
3. **Finalize job**: downloads artifacts, generates changelog, builds, validates, commits, opens PR
4. `validate.yml` runs on the PR as a status check
5. Human reviews and merges

### Market update (weekly) — monolithic

1. Cron fires at **02:00 UTC Sunday** (or manual dispatch)
2. Checks for open `market-update` PR — skips if one exists
3. Runs Claude Code agent with `market-update.md` (creates/deletes files in `data/tools/`, edits `data/observations.html`, edits `public/v1/changelog.json`)
4. Post-agent build: `assemble.sh` + `generate-index.sh` + `validate.sh`
5. If changes exist, commits `data/` + `public/` and opens a PR
6. Human reviews and merges

## Agent configuration

### Price update — research agent (per matrix job)

| Setting | Value |
|---------|-------|
| Model | `claude-sonnet-4-6` |
| Max turns | 18 |
| Budget cap | $0.50/job |
| Timeout | 15 minutes (includes all phases) |
| Parallelism | up to 12 (one per tool) |

**Allowed tools:** Read, Write, Glob, Grep, WebSearch, WebFetch, Bash (jq)
**Disallowed tools:** Agent, Edit (cannot modify existing files — writes findings only)

### Price update — validation agent (conditional, per matrix job)

| Setting | Value |
|---------|-------|
| Model | `claude-sonnet-4-6` |
| Max turns | 6 |
| Budget cap | $0.15/job |
| Runs when | Phase 2 diff detects price changes |

**Allowed tools:** Write, WebSearch, WebFetch
**Disallowed tools:** Agent, Edit, Read, Bash, Glob, Grep (clean slate — no repo access)

### Tool update (per matrix job)

| Setting | Value |
|---------|-------|
| Model | `claude-sonnet-4-6` |
| Max turns | 25 |
| Budget cap | $1.00/job |
| Timeout | 15 minutes |
| Parallelism | up to 12 (one per tool) |

**Allowed tools:** Read, Edit, Write, Glob, Grep, WebSearch, WebFetch, Bash (jq)
**Disallowed tools:** Agent (prevents subagent spawning that drains budget)

### Market update

| Setting | Value |
|---------|-------|
| Model | `claude-sonnet-4-6` |
| Max turns | 30 |
| Budget cap | $5/run |
| Timeout | 60 minutes |
| Parallelism | 1 |

**Allowed tools:** Read, Edit, Write, Glob, Grep, WebSearch, WebFetch, Bash (jq, ls, scripts)

## Safety layers

- `git add data/ public/` — only data and public files are committed
- Duplicate PR prevention — forces human review before next run proceeds
- Post-agent build + validation — `assemble.sh` + `generate-index.sh` + `validate.sh` run regardless
- `validate.yml` — independent PR check that rebuilds from source and checks for drift
- Branch protection — requires "Validate Data" check to pass before merge
- Independent labels (`price-update` / `market-update` / `tool-update`) — workflows don't block each other
- Matrix isolation — one tool's verification failure doesn't affect others
- **Research/edit separation** (price-update) — research agent cannot edit data files (Edit tool disallowed). Data file restored via `git checkout` after research phase as safety net.
- **Deterministic diff** (price-update) — jq script compares only price-bearing fields. Notes, capabilities, and editorial fields are structurally ignored, preventing notes drift.
- **Clean-slate validation** (price-update) — validation agent has no access to research agent's reasoning, runbook, or repo files. Can only fetch web content. Prevents confirmation bias.

## Error handling

| Failure | Mitigation |
|---------|-----------|
| Single tool agent crashes | Other tools unaffected; finalize job still runs |
| Budget exceeded | `--max-budget-usd` stops agent; partial changes uncommitted |
| Validation fails | No commit if exit code != 0 |
| Network errors | Runbook escalation ladder (step 6: mark UNVERIFIED) |
| GitHub rate limit | Job fails; retries next scheduled run |
| Open PR exists | Skips entire run |

## Spend estimate

### Price update (daily)

Per matrix job — Phase 1 research (Sonnet $3/$15 per M tokens):

| Phase | Input tokens | Output tokens |
|-------|-------------|--------------|
| Context loading (CLAUDE.md + runbook + tool file) | ~5K | ~1K |
| Verification (1-3 fetches) | ~8K | ~3K |
| **Total per tool (research)** | **~13K** | **~4K** |

Per matrix job — Phase 3 validation (conditional, Sonnet $3/$15 per M tokens):

| Phase | Input tokens | Output tokens |
|-------|-------------|--------------|
| Prompt + changes context | ~2K | ~1K |
| Vendor page fetch | ~5K | ~1K |
| **Total per tool (validation)** | **~7K** | **~2K** |

- **Research per job: ~$0.06-0.17** (same as before)
- **Validation per job: ~$0.05** (runs only when changes detected)
- **Per run (12 tools): ~$2.41** (validation adds ~$0-0.15 on change days)
- **Monthly (daily): ~$73-74** (validation adds ~$1-2/month)

### Tool update (weekly)

Per matrix job (Sonnet $3/$15 per M tokens):

| Phase | Input tokens | Output tokens |
|-------|-------------|--------------|
| Context loading (CLAUDE.md + runbook + tool file) | ~5K | ~1K |
| Vendor page fetch + comparison | ~15K | ~5K |
| **Total per tool** | **~20K** | **~6K** |

- **Per job: ~$0.15-0.30** (higher when structural changes found)
- **Per run (12 tools): ~$3.60**
- **Monthly (weekly): ~$15**

### Market update (weekly)

| Phase | Input tokens | Output tokens |
|-------|-------------|--------------|
| Context loading | ~15K | ~1K |
| Market scan (5 searches) | ~20K | ~5K |
| Health check (12 tools × 1 search) | ~30K | ~5K |
| Observations review | ~10K | ~5K |
| **Total** | **~75K** | **~16K** |

- **Per run: ~$2.41** (measured 2026-03-16)
- **Monthly (weekly): ~$10**

### Combined monthly

- **Estimated: ~$99/month** (includes conditional validation agents)
- **Anthropic console limit: $100/month** (set 50% email alert)
