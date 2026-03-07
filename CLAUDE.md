# CLAUDE.md

## Project

Taimi - AI Agent Market — a free, open pricing comparison page and JSON API for agentic AI coding tools. Curated by Kanto Company.

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

## Adding a new tool

1. Add entry to `tools` array in `public/v1/tools.json`
2. Increment `meta.tool_count`
3. Update `meta.updated_at`
4. Generate `public/v1/tools/{slug}.json`
5. Add row to `public/index.html`
6. Add changelog entry with type `new_tool`

## Style notes

The project values compactness over verbosity. Don't over-document. Don't add abstraction layers unless they solve a real problem. The entire "API" is static JSON files — that's a feature, not a limitation.
