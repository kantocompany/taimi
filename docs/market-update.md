# Market Update Runbook

Weekly procedure for keeping the tool list relevant and ensuring editorial quality. Run via GitHub Actions (`market-update.yml`).

Price verification is handled by the daily price-update workflow. Do not verify prices in this runbook.

## Build context

Read ALL of these files before starting:

1. `CLAUDE.md` — project rules and schema constraints
2. `public/v1/tools.json` — source of truth for all pricing data
3. `public/v1/changelog.json` — change history
4. `public/index.html` — the rendered pricing page (observations, links, display)
5. This file (`docs/market-update.md`)

Do not proceed to market scan until all files are loaded.

## Tool cap

Taimi tracks a maximum of **12 tools**. This cap keeps the dataset focused, CI costs manageable, and the comparison page scannable.

When a new tool qualifies for inclusion but the list is at cap, you must archive the lowest-ranked existing tool to make room. Use the ranking criteria below to decide.

### Ranking criteria

Rank all tools (existing + candidates) by overall market relevance. Use your judgment, informed by the signals gathered during the market scan. Consider:

- **Adoption:** GitHub stars, weekly downloads, enterprise customer lists, community mentions
- **Funding and backing:** Notable funding rounds, corporate backing, sustainability signals
- **Market presence:** Frequency in comparison articles, developer surveys, tech press
- **Differentiation:** Does this tool occupy a unique position? (e.g., only EU vendor, only BYOK terminal agent, only cloud sandbox)
- **Pricing transparency:** Tools with clear, public pricing are more valuable to Taimi's audience than opaque "contact sales" only products

A tool that ranks below all 12 current entries does not get added, even if it meets inclusion criteria.

### Archival process

When a tool is archived (dropped from active tracking or confirmed dead/acquired):

1. Remove the tool from the `tools[]` array in `tools.json`
2. Decrement `meta.tool_count`
3. Update `meta.updated_at`
4. **Keep** the individual `tools/{slug}.json` file as-is — it becomes a historical snapshot
5. Remove the tool's row from `index.html`
6. Add changelog entry with `type: "removed_tool"` and reason (e.g., "archived: ranked below cap", "discontinued", "acquired")

The orphaned `tools/{slug}.json` file will trigger a `validate.sh` warning — this is expected. Consumers hitting `tools/{slug}.json` still get the last-known data.

## Market scan

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
4. If the list is at cap (12 tools), rank the candidate against existing tools
5. If inclusion criteria met and ranked above an existing tool: add the candidate (CLAUDE.md "Adding a new tool"), archive the displaced tool (see archival process above)

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
   - If confirmed: archive the tool (see archival process above)
3. If the tool has been **rebranded** (name change, new parent company):
   - Update vendor info and slug if needed
   - Add changelog entry

### Part C — Document findings

Create `docs/YYYY-MM-DD-changes.md` as a **working document** during the cycle. Do not commit — it is gitignored.

- List all candidates found and whether they met criteria
- Rank all tools (existing + candidates) and note the reasoning
- List any existing tools flagged for removal/archival
- Note which searches were run and top results

## Representation review

1. **Annual vs monthly** — If the vendor shows both, are we showing monthly? If annual, does the notes field say so? (Convention: always show monthly price; note annual discount if significant.)
2. **Overage field fitness** — Does the overage object capture what an API consumer would need? If a tool has multiple models at different price points (e.g., Claude Code Sonnet vs Opus), can a consumer parsing output_per_million get a correct answer? If not, flag for schema restructure (split plans, add fields, or at minimum make notes unambiguous).
3. **Temporal state** — Is there a promo, beta, or sunset happening within 30 days? If yes, add a dated note: "Free through 2026-03-31, then $20/seat". If pricing is in active flux or community controversy, note it.
4. **Terminology drift** — Does the vendor still use the same language we do? If they renamed a plan or feature (e.g., "Team" → "Business", "premium requests" → "credits"), update even if the underlying mechanic is identical. Our plan names and notes should match what a user sees on the vendor's page.
5. **Missing or removed plans** — Has the vendor added new plan tiers or removed existing ones since our last update? Compare the plans in tools.json against the vendor's current pricing page. Add new plans, remove discontinued ones.
6. **Platform bundling clarity** — For platform plans, would a reader understand what they're actually buying? If the plan name or notes could mislead someone into thinking the price is for the coding tool alone, clarify.
7. **Sort attributes** — When prices change in index.html, verify that `data-*` sort attributes on the row wrapper match the updated values.

## Observations review

Run as the **last step**, after all data changes are complete.

The "Key observations" section in `public/index.html` is editorial analysis — it lives only in the HTML, not in tools.json. It must reflect current data.

1. Read each observation in the `<div class="observations">` section
2. Check every factual claim against the current tools.json data:
   - "cheapest individual plan" — is it still true?
   - Price ranges and multipliers — do the numbers match?
   - Vendor-specific claims (e.g., "only EU vendor") — still accurate?
3. Rewrite any observation that is factually stale
4. If a new tool was added or a major price shift occurred, consider adding or replacing an observation to highlight it
5. Keep the total to 5-6 bullet points — concise, not comprehensive

## Schema validation

Run after all data changes, before committing.

1. Generate individual tool files: `./scripts/generate-tool-files.sh`
2. Validate all files: `./scripts/validate.sh`
3. Do not commit if validation fails. Fix issues and re-run.
