#!/usr/bin/env bash
set -euo pipefail

# Generate individual tool JSON files from tools.json (single source of truth).
# Usage:
#   ./scripts/generate-tool-files.sh              # regenerate ALL tool files
#   ./scripts/generate-tool-files.sh cursor aider  # regenerate specific tools only

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_JSON="$REPO_ROOT/public/v1/tools.json"
TOOLS_DIR="$REPO_ROOT/public/v1/tools"

if [[ ! -f "$TOOLS_JSON" ]]; then
  echo "ERROR: $TOOLS_JSON not found" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }

# Extract meta block from tools.json
meta=$(jq '.meta' "$TOOLS_JSON")

# Determine which slugs to generate
if [[ $# -gt 0 ]]; then
  slugs=("$@")
else
  slugs=()
  while IFS= read -r s; do slugs+=("$s"); done < <(jq -r '.tools[].slug' "$TOOLS_JSON")
fi

generated=0
errors=0

for slug in "${slugs[@]}"; do
  tool=$(jq --arg s "$slug" '.tools[] | select(.slug == $s)' "$TOOLS_JSON")

  if [[ -z "$tool" || "$tool" == "null" ]]; then
    echo "SKIP: '$slug' not found in tools.json" >&2
    errors=$((errors + 1))
    continue
  fi

  outfile="$TOOLS_DIR/$slug.json"

  # Build the individual tool file: meta + tool wrapper
  jq -n --argjson meta "$meta" --argjson tool "$tool" \
    '{ meta: $meta, tool: $tool }' > "$outfile"

  echo "  ✓ $outfile"
  generated=$((generated + 1))
done

echo ""
echo "Generated: $generated file(s)"
[[ $errors -gt 0 ]] && echo "Errors: $errors" >&2 && exit 1
exit 0
