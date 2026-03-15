# Automated Daily Updates

## Overview

Daily pricing updates run via GitHub Actions using Claude Code. The agent executes the [update runbook](update-runbook.md), creates a PR for human review, and never touches main directly.

**Workflows:**
- `.github/workflows/update.yml` — daily agent run, creates PR
- `.github/workflows/validate.yml` — validates data on every PR targeting main

## How it works

1. Cron fires at **05:00 UTC** daily (or manual `workflow_dispatch`)
2. Checks for an open `automated-update` PR — skips if one exists
3. Creates branch `automated-update/YYYY-MM-DD`
4. Runs Claude Code agent with the update runbook
5. Post-agent validation (`generate-tool-files.sh` + `validate.sh`)
6. If changes exist, commits only `public/` files and opens a PR
7. `validate.yml` runs on the PR as a status check
8. Human reviews and merges → `deploy.yml` deploys to GitHub Pages

## Agent configuration

| Setting | Value | Rationale |
|---------|-------|-----------|
| Model | `claude-sonnet-4-6` | Structured runbook; Sonnet follows it well |
| Max turns | 30 | Full 6-phase cycle with headroom |
| Budget cap | $5/run | ~6x typical cost; stops runaway loops |
| Timeout | 30 minutes | Hard ceiling on job duration |
| Concurrency | 1 | No parallel runs |

**Allowed tools:** Read, Edit, Write, Glob, Grep, WebSearch, WebFetch, Bash (scripts, jq, git diff/status/log)

**Blocked tools:** Bash (rm, curl, wget, npm, pip, sudo)

## Safety layers

- `git add public/` — only public files are committed, regardless of what the agent touches
- Duplicate PR prevention — forces human review before next update proceeds
- Post-agent validation — runs even if the agent already ran validation
- `validate.yml` — independent PR check for all PRs (human or bot)
- Branch protection — requires "Validate Data" check to pass before merge (see setup)

## Error handling

| Failure | Mitigation |
|---------|-----------|
| Agent crashes | `timeout-minutes: 30` kills job; no branch pushed |
| Budget exceeded | `--max-budget-usd 5` stops agent; partial changes uncommitted |
| Validation fails | No commit if exit code != 0 |
| Protected file edited | `git add` scopes to `public/` only |
| Network errors | Runbook escalation ladder (step 6: mark UNVERIFIED) |
| GitHub rate limit | Job fails; retries next day |
| Open PR exists | Skips entire run |

## Spend estimate

Per-run cost (Sonnet $3/$15 per M tokens):

| Phase | Input tokens | Output tokens |
|-------|-------------|--------------|
| Context loading (5 files) | ~15K | ~1K |
| Market scan (5 searches + parsing) | ~20K | ~5K |
| Health check (12 tools × 1 search) | ~30K | ~5K |
| Price verification (12 × 1-3 fetches) | ~60K | ~10K |
| Representation + observations | ~10K | ~5K |
| Schema validation | ~5K | ~2K |
| **Total** | **~140K** | **~28K** |

- **Typical run: ~$0.85**
- **Monthly (daily): ~$25**
- **Hard cap (per run): $5.00**
- **Monthly hard cap (Anthropic console): $200**

If quality is insufficient with Sonnet, switching to Opus: ~$4/run, ~$120/month.
