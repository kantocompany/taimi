# Update Runbook

Weekly procedure for keeping the tool list relevant and prices accurate. The AI agent must follow this runbook during every update cycle in order: build context → market scan → price verification → observations review.

## Build context

Before making any changes, read ALL of these files into context:

1. `CLAUDE.md` — project rules and schema constraints
2. `public/v1/tools.json` — source of truth for all pricing data
3. `public/v1/changelog.json` — change history
4. `public/index.html` — the rendered pricing page (observations, links, display)
5. This file (`docs/update-runbook.md`) — you're reading it now

Do not proceed to market scan until all files are loaded.

## Market scan

Run every update cycle before price verification. Goal: ensure the tool list stays relevant — no missing contenders, no dead products.

### Part A — Discover new tools

Run these 5 searches. Each must be a separate WebSearch query to cover different angles. Do not skip any.

1. `"best AI coding tools [current-year]"` — ranking/listicle sites
2. `"AI coding agent launch [current-quarter]"` — recent product launches
3. `"AI code assistant funding [current-year]"` — funding = serious contender
4. `"AI coding tool comparison [current-year]"` — comparison articles
5. `site:news.ycombinator.com AI coding tool [current-year]` — developer community signal

For each tool that appears in **3+ of these searches** but is NOT in our list:

1. Verify it meets inclusion criteria (see below)
2. Add to the "Candidates" section of the update cycle document
3. Fetch its pricing page and document plan structure
4. If inclusion criteria met → follow CLAUDE.md "Adding a new tool" process

#### Inclusion criteria

ALL of these must be true:

- Is an **agentic coding tool** (autonomous or semi-autonomous code generation, not just autocomplete or chat)
- Has **public pricing** or a free tier (no stealth/waitlist-only products)
- Shows **adoption signals** from 2+ of: >5K GitHub stars, notable funding round, enterprise customers listed, >10K weekly downloads, featured in major tech press
- Has been **publicly available for 30+ days** (no launch-day hype)

### Part B — Health check existing tools

For each tool currently in tools.json:

1. WebSearch `"[tool name] shutdown OR discontinued OR acquired [current-year]"`
2. If results suggest the tool is dead, acquired, or merged:
   - Verify against official source
   - If confirmed → add changelog entry with `type: "removed_tool"`
   - Move to an `"archived"` section in tools.json (do not delete data)
3. If the tool has been **rebranded** (name change, new parent company):
   - Update vendor info and slug if needed
   - Add changelog entry

### Part C — Document findings

Write a "Market scan" section in the update cycle document (`docs/YYYY-MM-DD-changes.md`):

- List all candidates found and whether they met criteria
- List any existing tools flagged for removal/update
- Note which searches were run and top results

## Price verification escalation

For each vendor in `public/v1/tools.json`:

### Step 1 — Check known alternates

Before fetching the primary URL, check the [known alternates table](#known-alternate-urls) below. If an alternate exists, try it first.

### Step 2 — Fetch primary pricing URL

WebFetch `vendor.pricing_url` from tools.json.
- Success → extract prices, done.
- 403 / timeout / error → continue to step 3.

### Step 3 — Fetch vendor's developer docs

Many vendors have separate documentation sites (e.g., `developers.*.com/docs/pricing`) with less aggressive bot protection. WebFetch the docs URL.
- Success → extract prices, done.
- Fail → continue to step 4.

### Step 4 — Web search consensus

WebSearch `"[vendor name] pricing [current-year]"`.
- Need **3+ independent sources** agreeing on the same price.
- If consensus → mark as "verified via web search" in changelog.
- No consensus → continue to step 5.

### Step 5 — Community aggregator cross-check

Fetch a community-maintained pricing dataset:
- LiteLLM: `https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json`

Use only for sanity-checking, never as sole source. May lag 1-2 months.

### Step 6 — Mark UNVERIFIED

All methods failed. Do NOT silently keep stale data.
- Prefix the `notes` field in tools.json with `⚠ UNVERIFIED`
- Add changelog entry with `type: "unverified"`
- Log which methods were attempted and what failed
- Flag in the update cycle document (e.g., `docs/YYYY-MM-DD-changes.md`)

## Observations review

Run as the **last step** of every update cycle, after all data changes are complete.

The "Key observations" section in `public/index.html` is editorial analysis — it lives only in the HTML, not in tools.json. It must reflect current data.

1. Read each observation in the `<div class="observations">` section
2. Check every factual claim against the current tools.json data:
   - "cheapest individual plan" — is it still true?
   - Price ranges and multipliers — do the numbers match?
   - Vendor-specific claims (e.g., "only EU vendor") — still accurate?
3. Rewrite any observation that is factually stale
4. If a new tool was added or a major price shift occurred, consider adding or replacing an observation to highlight it
5. Keep the total to 5–6 bullet points — concise, not comprehensive

## Known alternate URLs

Vendors whose primary pricing URL blocks automated fetchers. Updated as new blocks are discovered.

| Vendor | Primary URL (blocked) | Alternate URL (working) | Verified |
|--------|----------------------|------------------------|----------|
| OpenAI | `openai.com/pricing` (Cloudflare 403) | `developers.openai.com/docs/pricing` | 2026-03-08 |

## Notes

- `chatgpt.com/pricing` is also blocked (same Cloudflare setup as openai.com)
- OpenAI's `robots.txt` allows `/pricing` but Cloudflare overrides it at the HTTP layer
- The alternate URL covers API token pricing only; subscription plans (Plus/Pro/Team) require web search consensus (step 4)
