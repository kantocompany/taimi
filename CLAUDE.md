# CLAUDE.md

## Project

Taimi — The AI Market Intelligence — a free, open pricing comparison page and JSON API for agentic AI coding tools. Curated by Kanto Company.

## Architecture

This is a static site. No build step, no framework, no dependencies. Everything deploys as-is to object storage.

- `public/v1/tools.json` is the **single source of truth** for all pricing data
- `public/v1/tools/{slug}.json` files are **derived** from tools.json — never edit these directly
- `public/v1/changelog.json` tracks price changes over time
- `public/index.html` is the human-readable pricing matrix page

## Critical rules

1. **tools.json is the source of truth.** All data flows from this file. Individual tool JSONs are generated from it. When index.html is eventually template-driven, it will also be generated from tools.json.

2. **Never fabricate pricing data.** If you update prices, you must verify against the vendor's official pricing page. Include the source URL. Wrong prices destroy the project's credibility.

3. **Always update changelog.json** when prices change. Every change needs: date, tool slug, type (pricing_change/feature/new_tool/removed_tool), description, and details with old/new values.

4. **Keep index.html visually aligned with Kanto branding.** Dark background (#0a0a0a), lime green accent (#AAFF00), Space Mono for headings/prices, DM Sans for body text. EU vendors get a green left border highlight.

5. **Every price block in index.html must link to the vendor's official pricing page.** No dead-end display-only prices.

6. **Preserve the API schema.** The JSON structure is a contract. Don't rename fields, change types, or restructure without updating schema_version in meta. Consumers may depend on the current shape.

## File relationships

```
tools.json ──→ tools/{slug}.json  (generated, 1:1)
tools.json ──→ index.html         (manual now, template-driven later)
any change ──→ changelog.json     (append-only log)
```

## Plan categories (enum)

`free`, `individual`, `team`, `enterprise`, `usage`

## Overage unit types (enum)

`token`, `request`, `acu`

## Platform bundling (optional fields)

Some tools are features within broader platform subscriptions (e.g., Claude Code is part of the Anthropic platform alongside Claude.ai, Cowork, etc.). Two optional fields express this:

- **`tool.platform`** — object with `name`, `bundled_with[]`, and optional `note`. Absent = standalone tool.
- **`plan.platform_plan`** — boolean. `true` = this plan is a platform subscription covering more than just the coding tool. Absent = standalone pricing.

In index.html, platform plans are marked with a superscript `P` badge and explained in the amber warning banner.

## Tool cap

Maximum **12 tools** in `tools.json`. When adding a new tool at cap, archive the lowest-ranked existing tool. See `docs/market-update.md` for ranking criteria and archival process.

## Adding a new tool

1. Check tool cap — if at 12, identify a tool to archive first
2. Add entry to `tools` array in `public/v1/tools.json`
3. Increment `meta.tool_count`
4. Update `meta.updated_at`
5. Generate `public/v1/tools/{slug}.json`
6. Add row to `public/index.html`. Use 🇪🇺 flag and "EU-based vendor" notation for `eu_based: true` vendors, country flag otherwise.
7. Add changelog entry with type `new_tool`

## Updating data

- **Prices:** Follow `docs/price-update.md` for the verification process. Never skip verification.
- **Tools (add/remove/health checks):** Follow `docs/market-update.md` for market scan and editorial review.

## Protected files

- `docs/price-update.md` — governs daily automated price verification. Read for guidance, never modify.
- `docs/market-update.md` — governs weekly market updates. Read for guidance, never modify.

## Style notes

The project values compactness over verbosity. Don't over-document. Don't add abstraction layers unless they solve a real problem. The entire "API" is static JSON files — that's a feature, not a limitation.
