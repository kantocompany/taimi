# Price Update Runbook

Verify pricing for a single tool. The workflow prompt provides today's date and the tool slug.

## Constraints

- **Read:** `CLAUDE.md`, `data/tools/{slug}.json`, this file
- **Write:** only `findings/{slug}.json` — your structured output
- Do **NOT** edit or write to `data/tools/` — a deterministic script applies changes after validation.
- Do not edit any other files. Do not commit or push. The workflow handles diffing, validation, changelog, assembly, generation, and git.
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

Overage rates (`overage.price_per_unit`) require the same extraction standard as base prices. If all sources are exhausted and no per-unit rate can be found, set the overage fields to `null` in your findings — the diff script will keep existing data unchanged when findings are null.

## Decision rules (mandatory)

1. **Price mismatch → include in findings** with the extracted amount and source evidence. A separate validation agent will verify before any data file changes.
2. **Missing plan → include it** with whatever price data you extracted.
3. **Removed plan → note it** in findings (the apply script handles removals).
4. **Renamed plan → note it** in findings.
5. **When in doubt, include the finding.** The validation phase decides. You are a researcher, not an editor.
6. **Never skip a discrepancy silently.** Include all findings even if uncertain — mark uncertain ones with `null` amounts.

## Verification procedure

### 0. Validate pricing URL

If `vendor.pricing_url` returns a non-200 status, redirects to a different domain, or does not contain pricing for this specific tool, note the working URL in your findings `source_url` field and proceed using the correct URL.

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

### 3. Record findings

Whether extraction succeeded or failed, write your findings to `findings/{slug}.json`. A deterministic diff script will compare your findings against current data and decide if changes exist.

### 4. Handle failure

If ALL sources failed, or you have reached web search (priority 5) without a successful extraction and are running low on turns — stop immediately. Set `status: "unverified"` in findings and record which methods failed in `extraction_failures`. Do not exhaust remaining turns on long-shot attempts.

## Output format

Your final action must be writing `findings/{slug}.json` with this schema:

```json
{
  "slug": "{slug}",
  "date": "{YYYY-MM-DD}",
  "status": "verified|changes_found|unverified",
  "source_url": "{url used for extraction}",
  "fetch_method": "direct|proxy|dev_docs|web_search|litellm",
  "plans": [
    {
      "id": "{plan id from current data}",
      "base_price_amount": 20.00,
      "overage": null
    },
    {
      "id": "{plan id}",
      "base_price_amount": null,
      "overage": {
        "input_per_million": 3.00,
        "output_per_million": 15.00,
        "price_per_unit": null
      }
    }
  ],
  "extraction_failures": [
    {"method": "direct", "error": "JS-rendered, no prices in response"}
  ]
}
```

**Schema rules:**
- Include only plans where you extracted at least one price field. Omit plans you could not verify.
- `base_price_amount`: the monthly (no-commitment) dollar amount. `null` if extraction failed for this plan.
- `overage`: include `input_per_million`, `output_per_million`, or `price_per_unit` as applicable. `null` if no overage or extraction failed.
- `extraction_failures`: record each failed fetch method (for debugging). Empty array if first method succeeded.
- `status`: `"verified"` if all prices match current data, `"changes_found"` if any differ, `"unverified"` if extraction failed entirely.

**Your final text message** must include exactly one status line:
- `✅ {slug}: verified` — prices match, no changes expected
- `✏️ {slug}: changes found` — findings include different prices
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
