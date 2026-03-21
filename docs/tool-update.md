# Tool Update Runbook

Deep structural review for a single tool. The workflow prompt provides today's date and the tool slug.

## Constraints

- **Read:** `CLAUDE.md`, `data/tools/{slug}.json`, this file
- **Edit:** only `data/tools/{slug}.json`
- Do not edit any other files. Do not commit or push. The workflow handles changelog, assembly, generation, and git.

## Procedure

### 1. Fetch vendor page

Fetch `vendor.pricing_url` from the tool file. If the page is JS-rendered or blocked, use the rendering proxy (`https://r.jina.ai/{url}`) or developer docs. If the tool has a `verification_override`, follow those fetch instructions.

### 2. Compare structure

List every purchasable plan tier on the vendor page. Compare against the plans in `data/tools/{slug}.json`. Note any differences — missing plans, removed plans, renamed plans, changed categories.

### 3. Review checklist

For this tool, check each item against the fetched vendor page:

1. **Annual vs monthly** — Are we showing the monthly (no-commitment) price? If the vendor offers annual billing at a lower rate, note it in the format `Annual billing: $X/mo`
2. **Overage field fitness** — Does the overage object capture what an API consumer would need? Is `mechanism` correct per the enum definitions in CLAUDE.md?
3. **Temporal state** — Is there a promo, beta, or sunset happening within 30 days? If yes, add a dated note
4. **Terminology drift** — Has the vendor renamed plans, features, or the product itself? `vendor.name` is the legal/parent company, not the product brand. Verify `vendor.pricing_url` still points to the correct page
5. **Missing or removed plans** — Add plans the vendor shows but we don't have. Remove plans the vendor no longer offers. Follow the schema of existing plans
6. **Platform bundling clarity** — For platform plans, would a reader understand what they're actually buying?
7. **Notes style** — Keep notes terse and factual. No marketing copy, no trailing periods. Match the style of existing tool files
8. **Usage plan coverage** — Has the vendor added new models at different price points? If a new model is the default or significantly different in price, add it as a separate usage plan entry
9. **Verification overrides** — If the tool has a `verification_override`, is it still needed? If the vendor fixed the issue, remove the field

### 4. Apply changes

Edit `data/tools/{slug}.json` for any issues found. When in doubt, make the change — a human reviews the PR.

## Post-review

**Required status output** — your final message must include exactly one of:
- `✅ {slug}: reviewed` — no structural changes needed
- `✏️ {slug}: updated` — file edited
- `⚠️ {slug}: UNVERIFIED` — vendor page not accessible
