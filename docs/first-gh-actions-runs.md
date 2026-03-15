# First GitHub Actions Runs — Findings

Date: 2026-03-14

## Run 1: Missing id-token permission

**Error:** `Unable to get ACTIONS_ID_TOKEN_REQUEST_URL env variable`

**Fix:** Added `id-token: write` to workflow permissions. The `claude-code-action@v1` requires OIDC token exchange regardless of auth method (API key, Bedrock, Vertex). It's a blanket requirement.

## Run 2: Missing Claude GitHub App

**Error:** `Claude Code is not installed on this repository. Please install the Claude Code GitHub App`

**Fix:** Installed the Claude Code GitHub App from https://github.com/apps/claude on the kantocompany/taimi repo.

## Run 3: Timeout at 30 minutes, no visibility

- Agent initialized with `claude-sonnet-4-6`, then silence until timeout.
- `--verbose` in `claude_args` did NOT surface output to workflow logs.
- Spend: ~$1.38
- Post-cancellation cleanup shows "Bad credentials" 401 on token revocation — harmless, token already expired.

## Run 4: Timeout at 45 minutes, still no visibility

- Added `--verbose` flag but it made no difference to log output.
- Cancelled manually, deleted logs.

## Run 5: Timeout at 60 minutes, with show_full_output

- Added `show_full_output: true` as action input — this worked, live output visible.
- Added `timeout-minutes: 60`.
- **Spend: $4.68** — way above $0.85 estimate, close to $5 budget cap.
- Agent completed 29 tool calls in 48 minutes before timeout.

### Tool call breakdown

| Tool | Count |
|------|-------|
| WebSearch | 13 |
| WebFetch | 10 |
| Read | 4 |
| ToolSearch | 2 |
| **Total** | **29** |

### Timeline (UTC)

| Time | Phase | Duration |
|------|-------|----------|
| 15:42 | Context loading (4 reads) | 2 min |
| 15:44 | Market scan — 5 searches + ToolSearch | 3 min |
| 15:47 | Market scan results processing | 10 min |
| 15:57 | Health checks — 7 searches | 13 min |
| 16:10 | Price verification — ToolSearch + WebFetches | 18 min |
| 16:28 | More WebFetches | 10 min |
| 16:38 | More WebSearches | timed out |

### Agent progress messages

1. "Now let me load all the required context files in parallel."
2. "Context fully loaded. Starting the market scan with all 5 required searches in parallel."
3. "Good data from the market scan. Now running Part B health checks on all existing tools in parallel."
4. "Important findings: Windsurf was acquired by Cognition AI (already correct in our data). Now running price verification for all vendors simultaneously."
5. Timed out during price verification phase.

### Root cause analysis

The runbook demands too much for a single agent run:
- 5 market scan searches
- 12 health check searches (one per tool)
- 12 price verifications (WebFetch per vendor, with escalation)
- = ~29+ web operations minimum

Each WebSearch/WebFetch result returns large HTML/text content (potentially 50-100K tokens). The 10-13 minute gaps between tool calls are the agent processing this massive context. The agent never reached the representation review, observations review, or validation phases.

**Cost was 5.5x the estimate** because the token estimate didn't account for the size of web content returned by WebSearch/WebFetch.

## Setup steps completed

1. Created Anthropic org account (Kanto Google SSO) — Organization type
2. Created `taimi-ci` API key
3. Set $100/month spend limit (kept default, not $200)
4. Set 50% ($50) email notification
5. Added `ANTHROPIC_API_KEY` to kantocompany/taimi repo secrets
6. Installed Claude Code GitHub App on the repo
7. Created `automated-update` label
8. Enabled "Read and write permissions" for Actions (org + repo level)
9. Enabled "Allow GitHub Actions to create and approve pull requests"
10. Set fork PR approval to "Require approval for all external contributors"

## Configuration discovered along the way

- `show_full_output: true` — required for live visibility in workflow logs
- `--verbose` in claude_args — does NOT surface to workflow logs
- `id-token: write` — required permission, even when using API key directly
- Claude Code GitHub App — must be installed on the repo

## Open issues for next iteration

1. **Run too slow/expensive** — need to split runbook into smaller scopes or reduce web operations per run
2. **Timeout too short** — 60 min wasn't enough for the full runbook
3. **Budget estimate wrong** — actual ~$4.68 vs estimated ~$0.85 per run
4. **Options to explore:**
   - Split into separate workflows (market scan vs price verification)
   - Rotate vendors (verify 4 per run, cycle through all every 3 days)
   - Skip market scan on most runs (weekly instead of daily)
   - Reduce health checks frequency
   - Consider if the runbook phases can be simplified for CI

## Next iteration — architecture options

1. **Opus vs Sonnet** — Opus is ~5x more expensive per token. The bottleneck isn't intelligence (Sonnet followed the runbook correctly) — it's volume of web content consuming tokens. Opus would cost more for the same work.

2. **Split approach (recommended):**
   - **GH Actions daily:** Price verification only (12 vendor checks). Skip market scan and health checks. Fewer web operations, faster, cheaper (~$1-2/run estimate).
   - **Locally weekly/biweekly:** Full runbook including market scan, health checks, observations review. Uses Claude Code subscription (no API costs). Human at keyboard for review.
   - Requires splitting the runbook into "price-only" and "full" modes.

3. **Local cron alternative:** macOS launchd job runs the full runbook when machine wakes up. No API costs (uses subscription). Downside: no run if machine is off.

4. **GH Actions weekly:** Keep current full-runbook approach but run weekly instead of daily. Accept ~$5/run, ~$20/month. Simpler but less frequent.

## Branch protection TODO (from docs/todo.md)

- Disable force pushes on main (currently `allow_force_pushes: true`)
- Add branch protection requiring "Validate Data" status check
- Consider `enforce_admins: true`
- Update design-decisions.md: CI/CD "In progress" → "Done", "weekly" → "daily"

## Current workflow state

Files committed and pushed to main:
- `.github/workflows/update.yml` — daily update (cron 05:00 UTC + manual dispatch)
- `.github/workflows/validate.yml` — PR validation
- `docs/automated-update.md` — operational documentation

Current settings in update.yml:
- `timeout-minutes: 60`
- `--max-turns 30`
- `--max-budget-usd 5`
- `--verbose` flag (no effect but present)
- `show_full_output: true` (debug, should remove for production)

Anthropic balance: $0.31 remaining (started with $4.99)

## Key insight

The infra works — the action runs, the agent follows the runbook, the validation pipeline is solid. The problem is purely economic (token cost per web fetch). Solvable by scoping runs narrower.

The agent spent 48 minutes processing 12 vendors' pricing pages. This proves Taimi's value — if a purpose-built agent struggles to gather scattered, bot-blocked, inconsistently formatted pricing data, a human with a spreadsheet has no chance of keeping it current. The moat is curation discipline, not technology.

Notable: the agent found Windsurf's acquisition by Cognition AI was "already correct in our data." The manual update cycles work. CI automation reduces toil, it doesn't fix a broken process.
