# Tool Update Runbook

Deep structural review for a single tool. The workflow prompt provides today's date and the tool slug.

## Constraints

- **Read:** `CLAUDE.md`, `data/tools/{slug}.json`, this file
- **Write:** only `findings/{slug}.json` — your structured output
- Do **NOT** edit or write to `data/tools/` — a deterministic script applies changes after validation.
- Do not edit any other files. Do not commit or push. The workflow handles diffing, validation, changelog, assembly, generation, and git.
- **Do not edit** `capabilities` or `benchmarks` fields in your proposed output. Copy them unchanged from the current data file.

## Procedure

### 1. Fetch vendor page

Fetch `vendor.pricing_url` from the tool file. If the page is JS-rendered or blocked, use the rendering proxy (`https://r.jina.ai/{url}`) or developer docs. If the tool has a `verification_override`, follow those fetch instructions.

**Source rule:** All plan and pricing data must be verifiable from `vendor.pricing_url` (or the pages specified in `verification_override`). Do not use search results, third-party comparison sites, or unrelated vendor pages as data sources. If you find relevant information elsewhere, add it as a note — do not change field values based on it.

### 2. Compare structure

List every plan tier on the vendor page, including free tiers and contact-sales tiers. Count them. Compare against the plans in `data/tools/{slug}.json` — count those too. If the counts differ, identify which plans are missing or extra. Note any differences — missing plans, removed plans, renamed plans, changed categories.

### 3. Review checklist

For this tool, check each item against the fetched vendor page:

1. **Annual vs monthly** — Are we showing the monthly (no-commitment) price? If the vendor offers annual billing at a lower rate, note it in the format `Annual billing: $X/mo`
2. **Overage field fitness** — Does the overage object capture what an API consumer would need? Is `mechanism` correct per the enum definitions in CLAUDE.md? If the vendor page does not explicitly describe the billing mechanism, set `mechanism` to `unverified` — never infer from other tools or from notes
3. **Temporal state** — Is there a promo, beta, or sunset happening within 30 days? If yes, add a dated note
4. **Terminology drift** — Has the vendor renamed plans, features, or the product itself? `vendor.name` is the legal/parent company, not the product brand — check footer, privacy policy, or terms page for the actual legal entity name. Verify `vendor.pricing_url` still points to the correct page
5. **Missing or removed plans** — Add plans the vendor shows but we don't have. Remove plans the vendor no longer offers. Follow the schema of existing plans. Verify each plan's `category` matches vendor positioning — "per user" or "for teams" language implies team, not individual
6. **Platform bundling clarity** — For platform plans, would a reader understand what they're actually buying?
7. **Feature-to-plan attribution** — Verify which tier each feature actually belongs to. Pricing pages often list features cumulatively or ambiguously — a feature shown near a plan may require a higher tier. Check for "Enterprise only", "Custom plan", "available on X and above", or similar qualifiers before attributing a feature to a specific plan's notes. If the pricing page doesn't confirm a feature's tier, check vendor docs or feature comparison pages before attributing it
8. **Notes style** — Keep notes terse and factual. No marketing copy, no trailing periods. Match the style of existing tool files
9. **Usage plan coverage** — Has the vendor added new models at different price points? If a new model is the default or significantly different in price, add it as a separate usage plan entry
10. **Verification overrides** — If the tool has a `verification_override`, is it still needed? If the vendor fixed the issue, remove the field

### 4. Record findings

Whether you found changes or not, write your findings to `findings/{slug}.json`. Read `schemas/tool-findings.json` for the exact schema.

Key rules:
- The `proposed` object must be the **complete tool JSON** as you believe it should look — including unchanged fields. The diff script compares it against current data.
- Copy `capabilities` and `benchmarks` unchanged from the current data file.
- Copy all price-bearing fields (`base_price.amount`, overage rates) unchanged — price accuracy is owned by the price-update pipeline.
- For new plans, include complete plan objects following the schema of existing plans.
- For plans you believe should be removed, simply omit them from `proposed.plans`. The diff script flags removals as warnings for human review — they are not auto-applied.
- `status`: `"reviewed"` if no changes needed, `"changes_found"` if your proposed JSON differs from current data, `"unverified"` if extraction failed entirely.

### 5. Handle failure

If the vendor page is not accessible after all fetch methods, set `status: "unverified"` and record extraction failures. Do not guess at structural changes.

## Post-review

**Required status output** — your final message must include exactly one of:
- `✅ {slug}: reviewed` — no structural changes needed
- `✏️ {slug}: changes found` — proposed JSON includes changes
- `⚠️ {slug}: UNVERIFIED` — vendor page not accessible
