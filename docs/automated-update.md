# Automated Updates

## Overview

Updates run via two GitHub Actions workflows using Claude Code. Both create PRs for human review — neither touches main directly.

| Workflow | Runbook | Schedule | Scope |
|----------|---------|----------|-------|
| `price-update.yml` | `docs/price-update.md` | Daily 05:00 UTC | Price verification (matrix: one agent per tool) |
| `market-update.yml` | `docs/market-update.md` | Weekly Sunday 02:00 UTC | Market scan, health checks, representation + observations review |

The two workflows have **zero overlap** in web operations. Price verification runs daily; the market update does not repeat it.

## How it works

### Price update (daily) — matrix architecture

1. **Setup job**: cron fires at 05:00 UTC (or manual dispatch). Checks for open PR, discovers tool slugs from `data/tools/*.json`
2. **Verify jobs** (parallel, one per tool): each runs Claude Code agent scoped to one vendor. Edits `data/tools/{slug}.json` if prices changed
3. **Finalize job**: downloads artifacts from all verify jobs, generates changelog entries from diffs, runs `assemble.sh` + `generate-index.sh` + `validate.sh`, commits `data/` + `public/`, opens PR
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

### Price update (per matrix job)

| Setting | Value |
|---------|-------|
| Model | `claude-sonnet-4-6` |
| Max turns | 18 |
| Budget cap | $0.50/job |
| Timeout | 10 minutes |
| Parallelism | up to 12 (one per tool) |

**Allowed tools:** Read, Edit, Write, Glob, Grep, WebSearch, WebFetch, Bash (jq)

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
- Independent labels (`price-update` / `market-update`) — workflows don't block each other
- Matrix isolation — one tool's verification failure doesn't affect others

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

Per matrix job (Sonnet $3/$15 per M tokens):

| Phase | Input tokens | Output tokens |
|-------|-------------|--------------|
| Context loading (CLAUDE.md + runbook + tool file) | ~5K | ~1K |
| Verification (1-3 fetches) | ~8K | ~3K |
| **Total per tool** | **~13K** | **~4K** |

- **Per job: ~$0.06-0.17** (higher when changes found)
- **Per run (12 tools): ~$0.72-2.04**
- **Monthly (daily): ~$22-62**

### Market update (weekly)

| Phase | Input tokens | Output tokens |
|-------|-------------|--------------|
| Context loading | ~15K | ~1K |
| Market scan (5 searches) | ~20K | ~5K |
| Health check (12 tools × 1 search) | ~30K | ~5K |
| Representation + observations | ~10K | ~5K |
| **Total** | **~75K** | **~16K** |

- **Estimated run: ~$1.50-2.50**
- **Monthly (weekly): ~$6-10**

### Combined monthly

- **Estimated: $28-72/month**
- **Anthropic console limit: $100/month** (set 50% email alert)
