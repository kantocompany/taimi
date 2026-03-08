# Design Decisions

This document captures why Taimi exists, the decisions behind its design, and where it's headed. It's the institutional memory of the project — read this before making structural changes.

## Origin story

This project emerged from a practical observation: the agentic AI coding tool market crossed from "pick one tool" to "compare 3-5 tools with incompatible pricing models" in early 2026. Procurement teams, FinOps leads, and developers face a $12K-$120K/year decision per team with no single source of truth.

We researched the existing landscape thoroughly (March 2026). The finding: **no single resource unifies subscription pricing with usage-based costs across agentic coding tools.** The ecosystem is split in two:

- **LLM API pricing** is well-served (LiteLLM JSON, OpenRouter API, PricePerToken MCP server) but covers only per-token model costs, not tool subscriptions
- **Tool subscription pricing** exists only in scattered blog posts (SaaS Price Pulse, DX, Tembo) with no API or machine-readable access

Taimi bridges this gap. One page, one API, covering both.

## Why "Market"

The name frames it as a **living market** rather than a static comparison page. Like a stock exchange provides price discovery in a market where bilateral negotiation doesn't scale, this provides transparent pricing in a market where every team currently googles, assembles spreadsheets, and asks peers. The name implies prices move, new entrants list, and the data stays current.

## Why free and open

The DevDocs model: free, open, indispensable. The page itself is the marketing for Kanto Company. Every time someone googles "Cursor vs Claude Code pricing," they land here, see Kanto's name, and make the trust transfer: "if they curate this data, they understand AI cost governance." This is a productized version of the authority-building blog strategy — except a blog post goes stale while a living market stays bookmarked.

The CC BY 4.0 data license encourages adoption. If other tools, dashboards, or MCP servers consume our JSON, that's distribution, not competition.

## Why static files, not a dynamic API

The entire dataset for 10 tools is ~19KB of JSON. Prices change monthly, not hourly. A static file behind a CDN answers every query pattern that matters, with:

- Zero infrastructure cost (object storage minimum tier)
- Zero operational burden (no servers, no databases, no uptime pager)
- Global performance (CDN edge caching)
- Trivial migration (S3-compatible, works on any provider)
- Full API semantics (CORS headers, proper content types, versioned paths)

The `/v1/` prefix is intentional. When (not if) the schema evolves, v2 can coexist.

## Data architecture decisions

### tools.json is the single source of truth

Every other file is derived:
- Individual tool files (`tools/{slug}.json`) are generated from tools.json
- The HTML page should eventually be template-generated from tools.json
- The changelog is the only independently maintained file

This means updating a price is a single edit in one place. Everything cascades.

### Plan categories are an enum, not free text

`free`, `individual`, `team`, `enterprise`, `usage` — these five categories let any consumer group comparable plans instantly. A tool asking "show me all individual plans under $50/mo" works without understanding each vendor's naming.

### Overage units are explicitly typed

The hardest comparison problem in this market: Copilot charges per request ($0.04), Anthropic/Mistral per token, Devin per ACU. These are fundamentally different units measuring different things. The API doesn't pretend they're comparable — it types them explicitly (`token`, `request`, `acu`) and lets consumers decide how to present the difference. The HTML page has a warning banner about this.

### base_price.per distinguishes seat vs flat pricing

Devin Team is $500/month flat, not per seat. Most other team plans are per-seat. The `per` field (`user`, `team`, `flat`) resolves this ambiguity, which changes the math completely for a 10-person team.

### Benchmarks are included but secondary

SWE-bench scores are included where available. They're useful for the ROI dimension (cost-per-capability), but they're not the primary purpose. The market is about price transparency first.

## Visual design decisions

### Kanto brand alignment

- Dark background (#0a0a0a) matching kantocompany.com
- Lime green (#AAFF00) as primary accent — from Kanto's favicon/brand
- Space Mono for prices and headings (technical, precise)
- DM Sans for body text (clean, readable)

### EU vendors get visual distinction

Mistral Vibe has a green left border and "EU-BASED VENDOR" badge. This is deliberate — European data sovereignty is a core concern for Kanto's clients, and the visual hierarchy should make EU options immediately scannable.

### Every price is a clickable link

No display-only prices. Every price block links to the vendor's official pricing page. This builds trust (verify the data yourself) and saves the user a search.

### The usage-based warning banner

The pink warning at the top of the matrix explicitly states that tokens, requests, and ACUs are not comparable. This honesty is a trust signal — we're not pretending apples are oranges.

## What's next (future roadmap)

### Done: AI-assisted updates (v2)

Implemented. The agent reads `docs/update-runbook.md` and executes a full update cycle: market scan (5 structured searches for new tools + health check of existing tools), price verification (6-step escalation with fallbacks for bot-blocked sites), and observations review. See `docs/update-runbook.md` for the full process.

The runbook is a protected file — the agent reads it but cannot modify it (enforced via Claude Code hooks and permission rules in CI).

### In progress: CI/CD pipeline

Weekly cron trigger runs the agent via API key. Agent commits changes and creates a PR for human review.

### v1.1: Template-driven HTML generation

Make index.html generated from tools.json via a simple script. This eliminates the manual sync between JSON data and HTML, making updates a single-file edit.

### v2.1: MCP server

Expose the pricing data as an MCP server so Claude Code, Cursor, and other AI tools can query it natively. A developer could ask their coding agent "what's the cheapest team plan for 10 developers?" and get an answer sourced from our data. PricePerToken already has an MCP server for LLM token pricing — we'd be the equivalent for tool-level pricing.

### v3: ROI dimension

Move beyond "what does it cost" to "what do you get per dollar." Track cost-per-task, tokens-per-outcome, benchmark scores normalized by price. The moment you can show "Claude Code solves SWE-bench problems at $X per solve vs Codex at $Y" — that's the signal procurement teams will pay attention to.

### Ongoing: expand tool coverage

The market scan process in the runbook handles this automatically. Current candidates to watch: Amazon Q Developer, JetBrains AI, Tabnine, Qodo, Replit, Aider, Kilo Code. Inclusion criteria are defined in the runbook.

## What this project is NOT

- Not a review site. No subjective ratings, no "best tool" recommendations.
- Not a benchmark site. SWE-bench scores are included for context, not as primary data.
- Not an affiliate play. No referral links, no sponsored placements.
- Not a real-time feed. Prices update when they change (monthly cadence typically), not continuously.

The value is in curation, accuracy, and structured access — not comprehensiveness or real-time speed.
