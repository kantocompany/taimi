# Price Update Runbook

Verify pricing for a single tool. The workflow prompt provides today's date and the tool slug.

## Constraints

- **Read:** `CLAUDE.md`, `data/tools/{slug}.json`, this file
- **Edit:** only `data/tools/{slug}.json`
- Do not edit any other files. Do not commit or push. The workflow handles changelog, assembly, generation, and git.
- **Pricing convention:** `base_price.amount` is always the monthly billing price. Annual discounts go in the plan's `notes` field, never in `base_price.amount`.
- **Plan boundaries:** A plan is a distinct purchasable tier with its own price. Eligibility discounts (student, OSS maintainer) are notes on the qualifying plan, not separate plan objects.

## What counts as a verified price

You must extract **specific dollar amounts** for each plan tier. If you can state "Plan X costs $Y/month" from fetched content, the extraction succeeded. Anything else — page skeleton without prices, marketing copy, interactive calculators, plan names without amounts — is a **failed extraction**.

Common failure modes that look like success:
- JS-rendered pages returning skeleton without dollar amounts
- Interactive calculators with no static price table
- Redirect chains landing on a different page
- Confusing credit allowances ("$25/mo of credits included") with subscription prices
- Pages showing plan names but prices behind a "See pricing" button
- "From $X/mo" or "starting at $X" = lowest tier price, not the price of the specific plan you're checking

## Decision rules (mandatory)

1. **Price mismatch → edit immediately.** The vendor's pricing page is the authority.
2. **Missing plan → add it.** Follow the schema of existing plans.
3. **Removed plan → remove it.**
4. **Renamed plan → update it.**
5. **When in doubt, make the change.** A human reviews the PR.
6. **Never skip a discrepancy silently.** Note it in the plan's `notes` field.

## Verification procedure

### 1. Fetch pricing

Try sources in order. Stop at the first successful extraction.

| Priority | Source | Method |
|----------|--------|--------|
| 1 | Known alternate URL (see table below) | WebFetch |
| 2 | `vendor.pricing_url` from tool file | WebFetch |
| 3 | Rendered version: `https://r.jina.ai/{pricing_url}` (handles JS-rendered pages) | WebFetch |
| 4 | Vendor developer docs (e.g., `developers.*.com/docs/pricing`) | WebFetch |
| 5 | Web search `"[vendor] pricing [year]"` — need **3+ sources agreeing** | WebSearch |
| 6 | LiteLLM dataset (sanity check only, may lag 1-2 months) | WebFetch `https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json` |

### 2. Compare and update

If extraction succeeded:
- Compare every `base_price.amount` and `overage` field against extracted prices
- If they match: done, no changes needed
- If they differ: edit `data/tools/{slug}.json` with correct values

### 3. Handle failure

If ALL sources failed, or you have reached web search (priority 4) without a successful extraction and are running low on turns — stop immediately and mark UNVERIFIED. Do not exhaust remaining turns on long-shot attempts.

- Prefix the first plan's `notes` with `UNVERIFIED`
- Log which methods you tried and what failed

## Post-verification

**Required status output** — your final message must include exactly one of:
- `✅ {slug}: verified` — prices match, no changes
- `✏️ {slug}: updated` — prices changed, file edited
- `⚠️ {slug}: UNVERIFIED` — all extraction methods failed

## Known alternate URLs

Vendors whose primary pricing URL blocks automated fetchers.

| Vendor | Primary (problem) | Alternate (working) | Verified |
|--------|-------------------|---------------------|----------|
| Anthropic | `claude.com/pricing` (JS-rendered) | None — rendering proxy (priority 3) handles this | 2026-03-16 |
| Mistral | `mistral.ai/pricing` (API pricing table is JS-rendered) | Subscription plans visible directly; API rates need rendering proxy (priority 3) or web search | 2026-03-16 |
| OpenAI | `openai.com/pricing` (Cloudflare 403) | `developers.openai.com/docs/pricing` | 2026-03-08 |
| Windsurf | `windsurf.com/pricing` (hangs/times out) | Use rendering proxy: `r.jina.ai/https://windsurf.com/pricing` | 2026-03-16 |

## Notes

- `chatgpt.com/pricing` is also blocked (same Cloudflare setup)
- Anthropic: primary URL is JS-rendered. Priority 3 (rendering proxy) will return the rendered content. Do NOT use `platform.claude.com/docs/en/about-claude/pricing` — it has unreliable subscription tier prices.
- OpenAI alternate covers API pricing only; subscription plans (Plus/Pro/Team) need web search consensus (priority 5)
- Windsurf: direct fetch hangs indefinitely. Always start with the rendering proxy.
- Mistral: subscription plan prices ($14.99 Pro, $24.99 Team) are in the static HTML. API token rates (per-model input/output) are in a JS-rendered table — use rendering proxy or web search.
