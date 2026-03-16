#!/usr/bin/env bash
# Add a new tool: check cap, create skeleton, prepend changelog entry.
# Usage: ./scripts/add-tool.sh <slug> "description text"
set -euo pipefail

MAX_TOOLS=12

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <slug> \"description\"" >&2
  exit 1
fi

SLUG="$1"
DESCRIPTION="$2"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="$REPO_ROOT/data/tools"
TOOL_FILE="$DATA_DIR/${SLUG}.json"
CHANGELOG="$REPO_ROOT/public/v1/changelog.json"
DATE=$(date -u +%Y-%m-%d)

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }

if ! [[ "$SLUG" =~ ^[a-z0-9-]+$ ]]; then
  echo "ERROR: Invalid slug format. Use lowercase letters, numbers, hyphens only." >&2
  exit 1
fi

if [[ -f "$TOOL_FILE" ]]; then
  echo "ERROR: $TOOL_FILE already exists" >&2
  exit 1
fi

current=$(ls "$DATA_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
if [[ "$current" -ge "$MAX_TOOLS" ]]; then
  echo "ERROR: At tool cap ($current/$MAX_TOOLS). Archive a tool first: bash scripts/archive-tool.sh <slug> \"reason\"" >&2
  exit 1
fi

jq -n --arg slug "$SLUG" '{
  slug: $slug,
  name: "TODO",
  vendor: {
    name: "TODO",
    hq_country: null,
    eu_based: false,
    pricing_url: "TODO"
  },
  plans: [
    {
      id: ($slug + "-free"),
      name: "Free",
      category: "free",
      base_price: { amount: 0, period: "monthly", per: "user" },
      includes: { premium_requests: null, tokens_included: null, notes: "TODO" },
      overage: null
    }
  ],
  capabilities: {
    autonomy_level: "TODO",
    ide_type: "TODO",
    model_choice: false,
    self_hosted: false,
    fedramp: false,
    eu_data_residency: false,
    soc2: false,
    on_premise: false
  },
  benchmarks: {
    swe_bench_pro: null,
    measured_at: null
  }
}' > "$TOOL_FILE"

jq --arg date "$DATE" \
   --arg tool "$SLUG" \
   --arg desc "$DESCRIPTION" \
   '.changes = [{date: $date, tool: $tool, type: "new_tool", description: $desc, details: {}}] + .changes
    | .meta.updated_at = ($date + "T00:00:00Z") | .meta.version = $date' \
   "$CHANGELOG" > "$CHANGELOG.tmp" && mv "$CHANGELOG.tmp" "$CHANGELOG"

new_count=$(ls "$DATA_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
echo "Added $SLUG: skeleton created, changelog updated. Tools: $new_count/$MAX_TOOLS"
echo "Next: edit data/tools/${SLUG}.json to fill in vendor, plans, and capabilities."
