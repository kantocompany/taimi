# Price Update Runbook

Daily procedure for verifying pricing accuracy across all tracked tools. Run via GitHub Actions (`price-update.yml`).

## Build context

Read these files before starting:

1. `CLAUDE.md` — project rules and schema constraints
2. `public/v1/tools.json` — source of truth for all pricing data
3. This file (`docs/price-update.md`)

Do not read index.html, changelog.json, or other docs unless a price change requires updating them.

## What counts as a successful price extraction

A fetch is only successful if you can extract **specific dollar amounts** for each plan tier. If the page returns HTML structure, plan names, or marketing copy but no actual prices, that is a **failed extraction** — treat it the same as a 403 and continue to the next step.

Common failure modes that look like success:
- JS-rendered pricing pages that return page skeleton without dollar amounts
- Pages that load an interactive calculator but no static price table
- Redirect chains that land on a different page than expected
- Pages that show plan names but prices are behind a "See pricing" button

When in doubt: if you cannot state "Plan X costs $Y/month" from the fetched content, the extraction failed.

## Price verification

For each vendor in `public/v1/tools.json`, compare every plan's `base_price.amount` and `overage` fields against the vendor's current pricing. Walk through the escalation steps below until you get a successful extraction.

### Step 1 — Check known alternates

Before fetching the primary URL, check the [known alternates table](#known-alternate-urls) below. If an alternate exists, try it first.

### Step 2 — Fetch primary pricing URL

WebFetch `vendor.pricing_url` from tools.json.
- Successful extraction (specific dollar amounts found): compare against tools.json, done.
- No dollar amounts extracted, 403, timeout, or error: continue to step 3.

### Step 3 — Fetch vendor's developer docs

Many vendors have separate documentation sites (e.g., `developers.*.com/docs/pricing`) with less aggressive bot protection. WebFetch the docs URL.
- Successful extraction: compare against tools.json, done.
- Fail: continue to step 4.

### Step 4 — Web search consensus

WebSearch `"[vendor name] pricing [current-year]"`.
- Need **3+ independent sources** agreeing on the same price.
- If consensus: compare against tools.json. Mark as "verified via web search" in changelog.
- No consensus: continue to step 5.

### Step 5 — Community aggregator cross-check

Fetch a community-maintained pricing dataset:
- LiteLLM: `https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json`

Use only for sanity-checking, never as sole source. May lag 1-2 months.

### Step 6 — Mark UNVERIFIED

All methods failed. Do NOT silently keep stale data.
- Prefix the `notes` field in tools.json with `UNVERIFIED`
- Add changelog entry with `type: "unverified"`
- Log which methods were attempted and what failed

### After verification

For each vendor, you must be in one of two states:
1. **Verified** — you extracted specific dollar amounts and compared them against tools.json. If they differ, update tools.json.
2. **UNVERIFIED** — all extraction methods failed. The tool is flagged.

There is no third state. "I fetched the page and it looked fine" without extracting dollar amounts is not verification.

## Post-verification

If any prices changed:

1. Update `public/v1/tools.json` with new values
2. Update `meta.updated_at` timestamp
3. Read `public/v1/changelog.json` and add entry with source URL
4. Read `public/index.html` and update corresponding plan prices
5. Verify `data-*` sort attributes on modified rows match new values

## Schema validation

Run after all changes:

1. Generate individual tool files: `./scripts/generate-tool-files.sh`
2. Validate: `./scripts/validate.sh`
3. Do not proceed if validation fails. Fix issues and re-run.

## Known alternate URLs

Vendors whose primary pricing URL blocks automated fetchers. Updated as new blocks are discovered.

| Vendor | Primary URL (problem) | Alternate URL (working) | Verified |
|--------|----------------------|------------------------|----------|
| Anthropic | `claude.com/pricing` (JS-rendered, no dollar amounts in HTML) | `platform.claude.com/docs/en/about-claude/pricing` | 2026-03-15 |
| OpenAI | `openai.com/pricing` (Cloudflare 403) | `developers.openai.com/docs/pricing` | 2026-03-08 |

## Notes

- `chatgpt.com/pricing` is also blocked (same Cloudflare setup as openai.com)
- OpenAI's `robots.txt` allows `/pricing` but Cloudflare overrides it at the HTTP layer
- The alternate URL covers API token pricing only; subscription plans (Plus/Pro/Team) require web search consensus (step 4)
- `claude.com/pricing` returns page skeleton with plan names but dollar amounts are in React components that don't render for web fetchers. The platform docs URL returns static markdown with full pricing tables.
