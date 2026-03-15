# Automated Updates

## Overview

Updates run via two GitHub Actions workflows using Claude Code. Both create PRs for human review — neither touches main directly.

| Workflow | Runbook | Schedule | Scope |
|----------|---------|----------|-------|
| `price-update.yml` | `docs/price-update.md` | Daily 05:00 UTC | Price verification for all vendors |
| `market-update.yml` | `docs/market-update.md` | Weekly Sunday 02:00 UTC | Market scan, health checks, representation + observations review |

The two workflows have **zero overlap** in web operations. Price verification runs daily; the market update does not repeat it.

## How it works

### Price update (daily)

1. Cron fires at **05:00 UTC** (or manual `workflow_dispatch`)
2. Checks for open `price-update` PR — skips if one exists
3. Creates branch `price-update/YYYY-MM-DD`
4. Runs Claude Code agent with `price-update.md`
5. Post-agent validation (`generate-tool-files.sh` + `validate.sh`)
6. If changes exist, commits only `public/` files and opens a PR
7. `validate.yml` runs on the PR as a status check
8. Human reviews and merges

### Market update (weekly)

1. Cron fires at **02:00 UTC Sunday** (or manual `workflow_dispatch`)
2. Checks for open `market-update` PR — skips if one exists
3. Creates branch `market-update/YYYY-MM-DD`
4. Runs Claude Code agent with `market-update.md`
5. Post-agent validation
6. If changes exist, commits only `public/` files and opens a PR
7. Human reviews and merges

## Agent configuration

| Setting | Price update | Market update |
|---------|-------------|---------------|
| Model | `claude-sonnet-4-6` | `claude-sonnet-4-6` |
| Max turns | 15 | 30 |
| Budget cap | $2/run | $5/run |
| Timeout | 30 minutes | 60 minutes |
| Concurrency | 1 | 1 |

**Allowed tools:** Read, Edit, Write, Glob, Grep, WebSearch, WebFetch, Bash (scripts, jq, git diff/status/log)

**Blocked tools:** Bash (rm, curl, wget, npm, pip, sudo)

**Visibility:** `show_full_output: true` — required for live output in workflow logs.

## Safety layers

- `git add public/` — only public files are committed, regardless of what the agent touches
- Duplicate PR prevention — forces human review before next run proceeds
- Post-agent validation — runs even if the agent already ran validation
- `validate.yml` — independent PR check for all PRs (human or bot)
- Branch protection — requires "Validate Data" check to pass before merge (see setup)
- Independent labels (`price-update` / `market-update`) — workflows don't block each other

## Error handling

| Failure | Mitigation |
|---------|-----------|
| Agent crashes | `timeout-minutes` kills job; no branch pushed |
| Budget exceeded | `--max-budget-usd` stops agent; partial changes uncommitted |
| Validation fails | No commit if exit code != 0 |
| Protected file edited | `git add` scopes to `public/` only |
| Network errors | Runbook escalation ladder (step 6: mark UNVERIFIED) |
| GitHub rate limit | Job fails; retries next scheduled run |
| Open PR exists | Skips entire run |

## Spend estimate

### Price update (daily)

Per-run cost (Sonnet $3/$15 per M tokens):

| Phase | Input tokens | Output tokens |
|-------|-------------|--------------|
| Context loading (3 files) | ~10K | ~1K |
| Price verification (12 vendors × 1-3 fetches) | ~50K | ~8K |
| Schema validation | ~5K | ~2K |
| **Total** | **~65K** | **~11K** |

- **Typical run: ~$0.90-1.50**
- **Monthly (daily): ~$27-45**
- **Hard cap (per run): $2.00**

### Market update (weekly)

Per-run cost estimate (TBD — test first):

| Phase | Input tokens | Output tokens |
|-------|-------------|--------------|
| Context loading (5 files) | ~15K | ~1K |
| Market scan (5 searches) | ~20K | ~5K |
| Health check (12 tools × 1 search) | ~30K | ~5K |
| Representation + observations | ~10K | ~5K |
| Schema validation | ~5K | ~2K |
| **Total** | **~80K** | **~18K** |

- **Estimated run: ~$1.50-2.50** (no price verification web fetches)
- **Monthly (weekly): ~$6-10**
- **Hard cap (per run): $5.00**

### Combined monthly

- **Estimated: $33-55/month**
- **Anthropic console limit: $100/month** (set 50% email alert)
