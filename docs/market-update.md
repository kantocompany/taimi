# Market Update Runbook

Weekly procedure for keeping the tool list relevant and ensuring editorial quality. Run via GitHub Actions (`market-update.yml`).

Price verification is handled by the daily price-update workflow. Do not verify prices in this runbook.

## Build context

Read ALL of these files before starting:

1. `CLAUDE.md` — project rules and schema constraints
2. `data/observations.html` — editorial observations snippet
3. `public/v1/changelog.json` — change history
4. This file (`docs/market-update.md`)

Also list the tool files: `ls data/tools/*.json` to see all tracked tools.

Do not read or edit `public/v1/tools.json`, `public/v1/tools/*.json`, or `public/index.html` — these are generated from source data by the workflow build step. Do not commit or push — the workflow handles git operations.

## Decision rules (mandatory)

1. **Finding → edit immediately.** When the market scan or representation review reveals a change, edit the relevant `data/tools/{slug}.json` file right away. Do not just note it — apply it.
2. **When in doubt, make the change.** A human reviewer will check the PR. False positives are far better than false negatives.
3. **Never skip a finding silently.** If you identify something that looks wrong but decide not to change it, add a note to the relevant plan's `notes` field explaining why.

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

    bash scripts/archive-tool.sh {slug} "reason for archival"

This deletes `data/tools/{slug}.json` and adds a `removed_tool` changelog entry atomically.

The old `public/v1/tools/{slug}.json` API file will persist as a historical snapshot until cleaned up.

### Adding a new tool

    bash scripts/add-tool.sh {slug} "description of the tool"

This checks the tool cap, creates a skeleton `data/tools/{slug}.json`, and adds a `new_tool` changelog entry. If at cap (12 tools), it exits with an error — archive a tool first.

After the script creates the skeleton, edit `data/tools/{slug}.json` to fill in vendor details, plans, and capabilities. Follow the schema of existing tool files.

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
5. If inclusion criteria met and ranked above an existing tool: add the candidate, archive the displaced tool

#### Inclusion criteria

ALL of these must be true:

- Is an **agentic coding tool** (autonomous or semi-autonomous code generation, not just autocomplete or chat)
- **Works with existing codebases** — integrates with developer workflows (IDE, terminal, or repository). Greenfield-only app generators (e.g., Lovable, Bolt, v0) are out of scope.
- Has **public pricing** or a free tier (no stealth/waitlist-only products)
- Shows **adoption signals** from 2+ of: >5K GitHub stars, notable funding round, enterprise customers listed, >10K weekly downloads, featured in major tech press
- Has been **publicly available for 30+ days** (no launch-day hype)

### Part B — Health check existing tools

For each tool in `data/tools/`:

1. WebSearch `"[tool name] shutdown OR discontinued OR acquired [current-year]"`
2. If results suggest the tool is dead, acquired, or merged:
   - Verify against official source
   - If confirmed: archive the tool (see archival process above)
3. If the tool has been **rebranded** (name change, new parent company):
   - Update the tool's `data/tools/{slug}.json` file
   - Add changelog entry

### Part C — Document findings

Create `docs/YYYY-MM-DD-changes.md` as a **working document** during the cycle. Do not commit — it is gitignored.

- List all candidates found and whether they met criteria
- Rank all tools (existing + candidates) and note the reasoning
- List any existing tools flagged for removal/archival
- Note which searches were run and top results

## Representation review

For each tool in `data/tools/`, read its file and check:

1. **Annual vs monthly** — If the vendor shows both, are we showing monthly? If annual, does the notes field say so? (Convention: always show monthly price; note annual discount if significant.)
2. **Overage field fitness** — Does the overage object capture what an API consumer would need? If a tool has multiple models at different price points, can a consumer parsing output_per_million get a correct answer? If not, flag for schema restructure.
3. **Temporal state** — Is there a promo, beta, or sunset happening within 30 days? If yes, add a dated note.
4. **Terminology drift** — Does the vendor still use the same language we do? If they renamed a plan or feature, update the tool file. `vendor.name` is the legal/parent company, not the product brand (the product brand is in `name`). Do not duplicate the product name into `vendor.name`.
5. **Missing or removed plans** — Has the vendor added new plan tiers or removed existing ones? Update the tool file.
6. **Platform bundling clarity** — For platform plans, would a reader understand what they're actually buying?
7. **Notes style** — Keep notes terse and factual: plan limits, pricing mechanics, key constraints. No marketing copy, no integration partner lists, no trailing periods. Match the style of existing tool files.

## Observations review

Run as the **last step**, after all data changes are complete.

The "Key observations" section lives in `data/observations.html`. It is editorial analysis that must reflect current data.

1. Read `data/observations.html`
2. Check every factual claim against the current tool data files:
   - "cheapest individual plan" — is it still true?
   - Price ranges and multipliers — do the numbers match?
   - Vendor-specific claims (e.g., "only EU vendor") — still accurate?
3. Rewrite any observation that is factually stale
4. If a new tool was added or a major price shift occurred, consider adding or replacing an observation
5. Keep the total to 5-6 bullet points — concise, not comprehensive

## Schema validation

The workflow runs `assemble.sh` + `generate-index.sh` + `validate.sh` after the agent completes. You do not need to run these yourself, but if you want to check your work locally: `bash scripts/assemble.sh && bash scripts/generate-index.sh && bash scripts/validate.sh`
