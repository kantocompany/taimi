# Price Update Runbook

Verify pricing for a single tool. The workflow prompt provides today's date and the tool slug.

## Constraints

- **Read:** `CLAUDE.md`, `data/tools/{slug}.json`, this file
- **Edit:** only `data/tools/{slug}.json`
- Do not edit any other files. Do not commit or push. The workflow handles changelog, assembly, generation, and git.
- **Pricing convention:** `base_price.amount` is always the monthly (no-commitment) billing price. If the vendor offers annual billing at a lower rate, note it in the format `Annual billing: $X/mo` — no other phrasing variations.
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
- Annual/monthly toggle defaulting to annual — prices and credit amounts from the annual view are NOT monthly prices
- "At API pricing," "usage-based," or "pay as you go" without a specific dollar amount per unit is a failed overage extraction — continue to the next source

Overage rates (`overage.price_per_unit`) require the same extraction standard as base prices. Do not replace existing concrete overage data with vague notes. If all sources are exhausted and no per-unit rate can be found, keep the existing overage data unchanged and prefix the plan's `notes` with `UNVERIFIED_OVERAGE`.

## Decision rules (mandatory)

1. **Price mismatch → edit immediately.** The vendor's pricing page is the authority.
2. **Missing plan → add it.** Follow the schema of existing plans.
3. **Removed plan → remove it.**
4. **Renamed plan → update it.**
5. **When in doubt, make the change.** A human reviews the PR.
6. **Never skip a discrepancy silently.** Note it in the plan's `notes` field.

## Verification procedure

### 0. Validate pricing URL

If `vendor.pricing_url` returns a non-200 status, redirects to a different domain, or does not contain pricing for this specific tool, update it to the correct URL before proceeding.

### 1. Check for verification override

Read the tool's `verification_override` field in the JSON file. If present, follow those instructions instead of the standard fetch procedure (§2). The override is the complete verification procedure for this tool — do not also run the standard procedure.

If no `verification_override` field exists, proceed to §2.

### 2. Fetch pricing

Try sources in order. Stop at the first successful extraction.

| Priority | Source | Method |
|----------|--------|--------|
| 1 | Known alternate URL (see table below) | WebFetch |
| 2 | `vendor.pricing_url` from tool file | WebFetch |
| 3 | Rendered version: `https://r.jina.ai/{pricing_url}` (handles JS-rendered pages) | WebFetch |
| 4 | Vendor developer docs (e.g., `developers.*.com/docs/pricing`) | WebFetch |
| 5 | Web search `"[vendor] pricing [year]"` — need **3+ sources agreeing** | WebSearch |
| 6 | LiteLLM dataset (sanity check only, may lag 1-2 months) | WebFetch `https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json` |

### 3. Compare and update

If extraction succeeded:
- Compare every `base_price.amount` and `overage` field against extracted prices
- If they match: done, no changes needed
- If they differ: edit `data/tools/{slug}.json` with correct values

### 4. Handle failure

If ALL sources failed, or you have reached web search (priority 5) without a successful extraction and are running low on turns — stop immediately and mark UNVERIFIED. Do not exhaust remaining turns on long-shot attempts.

- Prefix the first plan's `notes` with `UNVERIFIED`
- Log which methods you tried and what failed

## Post-verification

**Required status output** — your final message must include exactly one of:
- `✅ {slug}: verified` — prices match, no changes
- `✏️ {slug}: updated` — prices changed, file edited
- `⚠️ {slug}: UNVERIFIED` — all extraction methods failed

## Known fetch hints

Vendors whose pricing pages need alternate fetch methods. Tools with a `verification_override` field are not listed here — their override is the complete procedure.

| Vendor | Problem | Workaround | Verified |
|--------|---------|------------|----------|
| Anthropic | `claude.com/pricing` is JS-rendered | Rendering proxy (priority 3) handles this | 2026-03-16 |
| Mistral | `mistral.ai/pricing` API table is JS-rendered | Subscription plans visible directly; API rates need rendering proxy or web search | 2026-03-16 |
| OpenAI Codex | `openai.com/pricing` returns Cloudflare 403 | `developers.openai.com/codex/pricing` (subscriptions); `developers.openai.com/api/docs/pricing` (per-token API rates) | 2026-03-18 |

## Notes

- `chatgpt.com/pricing` is also blocked (same Cloudflare setup)
- Anthropic: do NOT use `platform.claude.com/docs/en/about-claude/pricing` — it has unreliable subscription tier prices.
- OpenAI Codex: Codex models may be listed under GPT-5.x-Codex names on the API pricing page.
- Mistral: subscription plan prices ($14.99 Pro, $24.99 Team) are in the static HTML. API token rates (per-model input/output) are in a JS-rendered table — use rendering proxy or web search.
