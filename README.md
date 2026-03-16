# Taimi — The AI Market Intelligence

A free, open pricing comparison for agentic AI coding tools. One page, one API, updated regularly.

Curated by [Kanto Company](https://www.kantocompany.com/) — Green Lean technology consultancy · Helsinki & Tampere.

## Why this exists

No single resource compiles agentic coding tool pricing in one place. Developers and procurement teams assemble data from 5+ vendor pages to compare tools with fundamentally different pricing models (flat subscriptions, token-based, request-based, agent compute units). This project aims to fix that.

## Live page

https://taimi.market

## API

Static JSON — no auth required, CORS enabled, CC BY 4.0 licensed.

```bash
# All tools
curl https://taimi.market/v1/tools.json

# Single tool
curl https://taimi.market/v1/tools/mistral-vibe.json

# Price change log
curl https://taimi.market/v1/changelog.json
```

Example queries with jq:

```bash
# EU-based vendors only
curl -s https://taimi.market/v1/tools.json | jq '.tools[] | select(.vendor.eu_based == true) | .name'

# Cheapest individual plans
curl -s https://taimi.market/v1/tools.json | jq '[.tools[].plans[] | select(.category == "individual") | {tool: .id, price: .base_price.amount}] | sort_by(.price)'

# Tools with self-hosted option
curl -s https://taimi.market/v1/tools.json | jq '[.tools[] | select(.capabilities.on_premise == true) | .name]'
```

## Project structure

```
data/
├── tools/
│   └── {slug}.json            # Source of truth — one file per tool
└── observations.html          # Editorial observations snippet
public/                        # Generated output — do not edit directly
├── index.html                 # Pricing comparison page (generated)
└── v1/
    ├── tools.json             # All tools assembled (generated)
    ├── changelog.json         # Price change history (append-only)
    └── tools/
        └── {slug}.json        # Per-tool API files (generated)
scripts/
├── assemble.sh                # data/tools/*.json → public/v1/
├── generate-index.sh          # tools.json → index.html
├── merge-changelog.sh         # Merge changes/*.json into changelog
├── local-price-update.sh      # Run price verification locally
├── local-market-update.sh     # Run market update locally
├── validate.sh                # Consistency checks
docs/
├── price-update.md            # Daily price verification runbook (protected)
├── market-update.md           # Weekly market update runbook (protected)
├── automated-update.md        # CI/CD architecture and spend estimates
├── design-decisions.md        # Architecture rationale and roadmap
├── focus-analysis.md          # FOCUS spec evaluation
```

## Building

```bash
./scripts/assemble.sh          # data/tools/ → public/v1/
./scripts/generate-index.sh    # public/v1/tools.json → public/index.html
./scripts/validate.sh          # check consistency
```

## Updating data

Two automated workflows keep data current:

- **Daily:** Price verification via matrix of Claude Code agents (one per tool)
- **Weekly:** Market scan, health checks, editorial review via `docs/market-update.md`

Manual updates: edit files in `data/tools/`, update `public/v1/changelog.json`, then run `./scripts/assemble.sh && ./scripts/generate-index.sh`.

### Local agent runs

Simulate the CI price-update matrix locally:

```bash
./scripts/local-price-update.sh              # all tools, sequential
./scripts/local-price-update.sh cursor aider  # specific tools only
./scripts/local-price-update.sh -j4           # all tools, 4 parallel
```

Handles agent runs, changelog fragment merge, assembly, generation, and validation. Logs per tool in `logs/`.

```bash
./scripts/local-market-update.sh              # weekly market scan + editorial review
```

## Hosting

GitHub Pages, deployed from `public/` via GitHub Actions (`.github/workflows/deploy.yml`).

- **Deploy trigger:** push to `main` or manual `workflow_dispatch`
- **Domain:** taimi.market
- **CORS:** enabled by default on public GitHub Pages (`Access-Control-Allow-Origin: *`)

## License

Data: CC BY 4.0 — free to use with attribution to Kanto Company.
Code: MIT.
