# CLAUDE.md

## Project

Taimi — The AI Market Intelligence — a free, open pricing comparison page and JSON API for agentic AI coding tools. Curated by Kanto Company.

## Architecture

Static site with a build step: source data in `data/`, generated output in `public/`. Dependencies: `jq` and `bash` only.

- `data/tools/{slug}.json` files are the **single source of truth** — one file per tool, containing just the tool object
- `public/v1/tools.json` is **assembled** from data/tools/ — never edit directly
- `public/v1/tools/{slug}.json` files are **generated** API files — never edit directly
- `public/index.html` is **generated** from tools.json — never edit directly
- `data/observations.html` is the editorial observations snippet included in index.html
- `public/v1/changelog.json` tracks price changes over time (append-only)
- `schemas/` contains pipeline intermediate schemas (price findings, validation verdicts) — NOT tool data schemas. Tool data structure is convention-based, not schema-locked.

## Data flow

```
data/tools/{slug}.json        ← SOURCE OF TRUTH (edit these)
        │
scripts/assemble.sh           ← reads data/tools/*.json
        │
        ├──→ public/v1/tools.json         (assembled)
        └──→ public/v1/tools/{slug}.json  (generated API files)
                │
scripts/generate-index.sh     ← reads tools.json + data/observations.html
                │
                └──→ public/index.html    (generated)
```

Build: `./scripts/assemble.sh && ./scripts/generate-index.sh`
Validate: `./scripts/validate.sh`

## Critical rules

1. **data/tools/ files are the source of truth.** All data flows from these files. Never edit public/v1/ files directly — they are generated.

2. **Never fabricate pricing data.** If you update prices, you must verify against the vendor's official pricing page. Include the source URL. Wrong prices destroy the project's credibility.

3. **Always record price changes.** Format: date, tool slug, type (pricing_change/feature/new_tool/removed_tool), description, and details with source URL. See the active runbook for where to write the entry.

4. **Preserve the API schema.** The JSON structure is a contract. Don't rename fields, change types, or restructure without updating schema_version in meta (current: `1.2`). Consumers may depend on the current shape.

5. **index.html is generated.** Branding (dark background, lime green accent, Space Mono/DM Sans fonts, EU green border) is maintained in `scripts/generate-index.sh`. Do not hand-edit public/index.html.

## Plan categories (enum)

`free`, `individual`, `team`, `enterprise`, `usage`

## Overage unit types (enum)

`token`, `request`, `acu`

## Overage mechanism types (enum)

- `automatic` — vendor bills beyond included usage with no user action required
- `add_on` — user must purchase additional capacity to continue beyond included usage
- `byok` — tool vendor does not bill; user brings their own API key to a third-party LLM provider
- `unverified` — mechanism could not be determined from vendor pricing page

`mechanism` must be verified from the vendor pricing page, not inferred from notes or other tools.

## Platform bundling (optional fields)

Some tools are features within broader platform subscriptions (e.g., Claude Code is part of the Anthropic platform alongside Claude.ai, Cowork, etc.). Two optional fields express this:

- **`tool.platform`** — object with `name`, `bundled_with[]`, and optional `note`. Absent = standalone tool.
- **`plan.platform_plan`** — boolean. `true` = this plan is a platform subscription covering more than just the coding tool. Absent = standalone pricing.

In index.html, platform plans are marked with a superscript `P` badge and explained in the amber warning banner.

## Verification overrides (optional field)

**`tool.verification_override`** — string. When present, the price-update agent follows these instructions instead of the standard fetch procedure. Absent = standard procedure applies.

Use for vendors where automated fetching produces **wrong results** (e.g., JS-only toggle showing annual prices, unresolvable "at API pricing" requiring cross-tool lookup). Do not use for simple fetch failures — those belong in the "Known fetch hints" table in `docs/price-update.md`.

Source-only field — `assemble.sh` strips it from public API output.

## First-pass provenance flag (optional field)

**`tool._notes_first_pass`** — boolean. `true` signals that the tool's plan notes were written by an unvalidated source (typically market-update agent on first add). Tool-update reads the flag and treats existing notes as proposed rather than authoritative — verifies each claim against the vendor page, scrubs unverifiable claims, and proposes additions for omitted vendor-page features. Cleared automatically by `apply-tool-findings.sh` after the first tool-update run.

Set automatically by `scripts/add-tool.sh` when creating a new tool skeleton. Source-only field — `assemble.sh` strips it from public API output.

**`tool._capabilities_first_pass`** — boolean. Same mechanism as `_notes_first_pass` but for the `capabilities` block. When set, tool-update may propose capability changes (verified against vendor page) and `apply-tool-findings.sh` applies validator-confirmed changes; when absent, capabilities are protected from edits and preserved from the original data. Set by `add-tool.sh`, cleared by `apply-tool-findings.sh`. Source-only field — `assemble.sh` strips it from public API output.

## Conditional-hold marker (optional field)

**`plan._pending`** — string. A deferred "revisit when vendor publishes X" decision encoded as source-only data state (e.g. `"vendor-publishes-org-rate"`). Set manually by the operator on a plan whose final shape is blocked on something the vendor has not yet published. Every update cycle re-presents all `_pending` plans (`validate.sh` warning + `diff-summary.sh` section) so the open decision never goes silent. Remove the marker once resolved.

Source-only field — stripped from public API output and from diff/changelog comparison everywhere the other `_`-prefixed fields are stripped.

## Notes must not duplicate structured fields

Plan `notes` carry prose context only. Numeric values that already live in a structured field — `overage.price_per_unit`, `overage.input_per_million` / `output_per_million`, `includes.premium_requests` — must not be restated in notes. `index.html` renders these structured fields directly (premium-request counts via a render helper in `generate-index.sh`); duplicating them in prose causes drift between the two copies. `validate.sh` **fails the build** if an `overage.notes` fragment of the form `$N/<unit>` restates the structured rate for that plan's `overage.unit`. Unit-carrier prose for units with no structured field (session-hour, container-hour, effort) is exempt.

## Plan observation timestamp (`_last_seen_on_page`)

Source-only per-plan field recording when the tool-update agent last saw the plan on the vendor page. The research agent sets it to today **only** for plans it directly observed during this fetch; plans listed from prior knowledge keep their existing value. `apply-tool-findings.sh` honors this — an unobserved plan's clock keeps aging toward the 21-day auto-removal threshold, so the agent's "not visible this cycle" signal stays load-bearing. Stripped from public API output.

## Tool cap

Maximum **12 tools** in `data/tools/`. When adding a new tool at cap, archive the lowest-ranked existing tool. See `docs/market-update.md` for ranking criteria and archival process.

## Adding a new tool

1. Check tool cap — if at 12, archive first
2. `bash scripts/add-tool.sh {slug} "description"` (creates skeleton + changelog entry)
3. Edit `data/tools/{slug}.json` to fill in vendor, plans, capabilities
4. Build: `./scripts/assemble.sh && ./scripts/generate-index.sh` (automated workflows handle this)

## Removing a tool

1. `bash scripts/archive-tool.sh {slug} "reason"` (deletes file + adds changelog entry)
2. Build: `./scripts/assemble.sh && ./scripts/generate-index.sh` (automated workflows handle this)

## Updating data

- **Prices:** Follow `docs/price-update.md` for the verification process. Never skip verification. Price-update uses a four-phase pipeline: research agent (no edit permission) → deterministic diff → conditional validation agent (clean slate) → deterministic apply. No AI agent edits `data/tools/` directly.
- **Tool structure:** Follow `docs/tool-update.md` for weekly structural review (plans, categories, notes).
- **Tools (add/remove/health checks):** Follow `docs/market-update.md` for market scan and editorial review. Market-update's data write scope is **tool-set membership only** (whole-file add via `add-tool.sh` / remove via `archive-tool.sh`) plus `data/observations.html` and `changelog.json`. Intra-file field edits to a surviving tool — plans, notes, terminology/rebrand, prices — are tool-update / price-update scope, **enforced** by `scripts/guard-market-update.sh` (reverts violations after the agent runs).
- **Observations:** Edit `data/observations.html` directly.

## Protected files

- `docs/price-update.md` — governs daily automated price verification. Read for guidance, never modify.
- `docs/tool-update.md` — governs weekly structural review. Read for guidance, never modify.
- `docs/market-update.md` — governs weekly market updates. Read for guidance, never modify.

## Style notes

The project values compactness over verbosity. Don't over-document. Don't add abstraction layers unless they solve a real problem. The entire "API" is static JSON files — that's a feature, not a limitation.
