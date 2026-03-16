#!/usr/bin/env bash
set -euo pipefail

# Assemble public/v1/tools.json and public/v1/tools/{slug}.json from
# individual source files in data/tools/.
#
# data/tools/{slug}.json  →  public/v1/tools.json (meta + tools[] array)
#                          →  public/v1/tools/{slug}.json (meta + tool wrapper)
#
# Usage: ./scripts/assemble.sh

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="$REPO_ROOT/data/tools"
OUT_JSON="$REPO_ROOT/public/v1/tools.json"
OUT_DIR="$REPO_ROOT/public/v1/tools"

if [[ ! -d "$DATA_DIR" ]]; then
  echo "ERROR: $DATA_DIR not found" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }

# Collect all source files
shopt -s nullglob
files=("$DATA_DIR"/*.json)
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  echo "ERROR: No JSON files in $DATA_DIR" >&2
  exit 1
fi

tool_count=${#files[@]}
# Use ASSEMBLE_DATE env var if set (update workflows), else preserve existing, else now
if [[ -n "${ASSEMBLE_DATE:-}" ]]; then
  updated_at="${ASSEMBLE_DATE}T00:00:00Z"
  version="$ASSEMBLE_DATE"
elif [[ -f "$OUT_JSON" ]]; then
  updated_at=$(jq -r '.meta.updated_at' "$OUT_JSON")
  version=$(jq -r '.meta.version' "$OUT_JSON")
else
  updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  version=$(date -u +%Y-%m-%d)
fi

echo "Assembling $tool_count tools..."

# --- Build tools.json ---
# Read all tool files, sort by slug, wrap in meta envelope
jq -n \
  --arg version "$version" \
  --arg updated_at "$updated_at" \
  --argjson tool_count "$tool_count" \
  --slurpfile tools <(jq -s 'sort_by(.slug)' "${files[@]}") \
  '{
    meta: {
      version: $version,
      updated_at: $updated_at,
      currency: "USD",
      schema_version: "1.0",
      source: "https://taimi.market",
      maintainer: "Kanto Company",
      license: "CC BY 4.0",
      tool_count: $tool_count
    },
    tools: $tools[0]
  }' > "$OUT_JSON"

echo "  ✓ $OUT_JSON ($tool_count tools)"

# --- Build individual API files ---
# Each gets the same meta block + { "meta": ..., "tool": ... } wrapper
meta=$(jq '.meta' "$OUT_JSON")

mkdir -p "$OUT_DIR"
generated=0

for file in "${files[@]}"; do
  slug=$(jq -r '.slug' "$file")
  outfile="$OUT_DIR/$slug.json"

  jq -n --argjson meta "$meta" --argjson tool "$(cat "$file")" \
    '{ meta: $meta, tool: $tool }' > "$outfile"

  echo "  ✓ $outfile"
  generated=$((generated + 1))
done

echo ""
echo "Assembled: $OUT_JSON + $generated individual files"
