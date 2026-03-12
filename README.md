# Taimi - AI Agent Market

A free, open pricing comparison for agentic AI coding tools. One page, one API, updated regularly.

Curated by [Kanto Company](https://www.kantocompany.com/) — Green Lean technology consultancy · Helsinki & Tampere.

## Why this exists

No single resource compiles agentic coding tool pricing in one place. Developers and procurement teams assemble data from 5+ vendor pages to compare tools with fundamentally different pricing models (flat subscriptions, token-based, request-based, agent compute units). This project aims to fix that.

## What's included

**10 tools tracked:** Claude Code, Cursor, GitHub Copilot, OpenAI Codex, Mistral Vibe, Windsurf, Devin, Augment Code, Cline, Google Antigravity.

**Dimensions per tool:** free tier, individual plans, team/seat pricing, usage-based (PAYG), enterprise options, vendor HQ/EU status, capabilities, and benchmarks.

## Live page

Hosted on GitHub Pages. Deployed automatically on push to `main` via GitHub Actions.

URL: TODO (pending custom domain setup)

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
docs/
├── update-runbook.md          # Automated update process (protected, read-only for agents)
```

## Updating data

Automated weekly updates follow `docs/update-runbook.md` — market scan, price verification, observations review.

To simulate an update cycle locally:

```bash
claude "Read docs/update-runbook.md and execute a full update cycle. Commit all changes and create a PR."
```

Manual updates: edit `public/v1/tools.json`, update `changelog.json`, regenerate individual tool files and `index.html`.

## Hosting

GitHub Pages, deployed from `public/` via GitHub Actions (`.github/workflows/deploy.yml`).

- **Deploy trigger:** push to `main` or manual `workflow_dispatch`
- **Custom domain:** configure in repo Settings > Pages once DNS is ready
- **CORS:** enabled by default on public GitHub Pages (`Access-Control-Allow-Origin: *`)

## License

Data: CC BY 4.0 — free to use with attribution to Kanto Company.
Code: MIT.
