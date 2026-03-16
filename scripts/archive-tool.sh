#!/usr/bin/env bash
# Archive a tool: delete source file + prepend changelog entry.
# Usage: ./scripts/archive-tool.sh <slug> "reason text"
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <slug> \"reason\"" >&2
  exit 1
fi

MAX_TOOLS=12
SLUG="$1"
REASON="$2"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL_FILE="$REPO_ROOT/data/tools/${SLUG}.json"
CHANGELOG="$REPO_ROOT/public/v1/changelog.json"
DATE=$(date -u +%Y-%m-%d)

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }

if [[ ! -f "$TOOL_FILE" ]]; then
  echo "ERROR: $TOOL_FILE does not exist" >&2
  exit 1
fi

NAME=$(jq -r '.name' "$TOOL_FILE")
rm "$TOOL_FILE"

jq --arg date "$DATE" \
   --arg tool "$SLUG" \
   --arg desc "Archived $NAME. $REASON" \
   --arg reason "$REASON" \
   '.changes = [{date: $date, tool: $tool, type: "removed_tool", description: $desc, details: {reason: $reason}}] + .changes
    | .meta.updated_at = ($date + "T00:00:00Z") | .meta.version = $date' \
   "$CHANGELOG" > "$CHANGELOG.tmp" && mv "$CHANGELOG.tmp" "$CHANGELOG"

remaining=$(ls "$REPO_ROOT/data/tools/"*.json 2>/dev/null | wc -l | tr -d ' ')
echo "Archived $NAME ($SLUG): file deleted, changelog updated. Tools: $remaining/$MAX_TOOLS"
