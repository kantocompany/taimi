# Taimi - AI Agent Market

A free, open pricing comparison for agentic AI coding tools. One page, one API, updated regularly.

Curated by [Kanto Company](https://www.kantocompany.com/) — a sustainability-focused cloud consultancy based in Finland.

## Why this exists

No single resource compiles agentic coding tool pricing in one place. Developers and procurement teams assemble data from 5+ vendor pages to compare tools with fundamentally different pricing models (flat subscriptions, token-based, request-based, agent compute units). This project aims to fix that.

## What's included

**10 tools tracked:** Claude Code, Cursor, GitHub Copilot, OpenAI Codex, Mistral Vibe, Windsurf, Devin, Augment Code, Cline, Google Antigravity.

**Dimensions per tool:** free tier, individual plans, team/seat pricing, usage-based (PAYG), enterprise options, vendor HQ/EU status, capabilities, and benchmarks.

## Live page

TODO

## API

Static JSON — no auth required, CORS enabled, CC BY 4.0 licensed.

```bash
# All tools
curl https://taimi.com/v1/tools.json

# Single tool
curl https://taimi.com/v1/tools/mistral-vibe.json

# Price change log
curl https://taimi.com/v1/changelog.json
```

Example queries with jq:

```bash
# EU-based vendors only
curl -s .../v1/tools.json | jq '.tools[] | select(.vendor.eu_based == true) | .name'

# Cheapest individual plans
curl -s .../v1/tools.json | jq '[.tools[].plans[] | select(.category == "individual") | {tool: .id, price: .base_price.amount}] | sort_by(.price)'

# Tools with self-hosted option
curl -s .../v1/tools.json | jq '[.tools[] | select(.capabilities.on_premise == true) | .name]'
```

## Project structure

```
public/
├── index.html                 # The pricing comparison page
└── v1/
    ├── tools.json             # All tools — the single source of truth
    ├── changelog.json         # Price change history
    └── tools/
        └── {slug}.json        # Individual tool files (derived from tools.json)
```

## Updating data

1. Edit `public/v1/tools.json`
2. Add entry to `public/v1/changelog.json`
3. Regenerate individual tool files and `index.html` (see docs/design-decisions.md)
4. Commit, push, deploy

## Hosting

TODO

## License

Data: CC BY 4.0 — free to use with attribution to Kanto Company.
Code: MIT.
