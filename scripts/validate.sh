#!/usr/bin/env bash
set -euo pipefail

# Validate consistency across all Taimi data files.
# Run at the end of every update cycle before committing.
# Usage: ./scripts/validate.sh

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_JSON="$REPO_ROOT/public/v1/tools.json"
CHANGELOG="$REPO_ROOT/public/v1/changelog.json"
TOOLS_DIR="$REPO_ROOT/public/v1/tools"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }

errors=0
warnings=0

echo "=== Taimi Data Validation ==="
echo ""

# --- 1. tools.json is valid JSON ---
if ! jq empty "$TOOLS_JSON" 2>/dev/null; then
  echo "FAIL: tools.json is not valid JSON"
  exit 1
fi
echo "✓ tools.json is valid JSON"

# --- 2. tool_count matches actual count ---
declared=$(jq '.meta.tool_count' "$TOOLS_JSON")
actual=$(jq '.tools | length' "$TOOLS_JSON")
if [[ "$declared" != "$actual" ]]; then
  echo "FAIL: meta.tool_count ($declared) != actual tools count ($actual)"
  ((errors++))
else
  echo "✓ tool_count matches ($actual tools)"
fi

# --- 3. No duplicate slugs ---
dupes=$(jq -r '[.tools[].slug] | group_by(.) | map(select(length > 1)) | .[][][]' "$TOOLS_JSON")
if [[ -n "$dupes" ]]; then
  echo "FAIL: Duplicate slugs: $dupes"
  ((errors++))
else
  echo "✓ No duplicate slugs"
fi

# --- 4. Every tool has a matching individual file ---
slugs=()
while IFS= read -r s; do slugs+=("$s"); done < <(jq -r '.tools[].slug' "$TOOLS_JSON")
missing_files=()
for slug in "${slugs[@]}"; do
  if [[ ! -f "$TOOLS_DIR/$slug.json" ]]; then
    missing_files+=("$slug")
  fi
done
if [[ ${#missing_files[@]} -gt 0 ]]; then
  echo "FAIL: Missing individual files: ${missing_files[*]}"
  ((errors++))
else
  echo "✓ All ${#slugs[@]} individual tool files exist"
fi

# --- 5. No orphan files in tools/ ---
orphans=()
for f in "$TOOLS_DIR"/*.json; do
  [[ ! -f "$f" ]] && continue
  fname=$(basename "$f" .json)
  if ! jq -e --arg s "$fname" '.tools[] | select(.slug == $s)' "$TOOLS_JSON" >/dev/null 2>&1; then
    orphans+=("$fname")
  fi
done
if [[ ${#orphans[@]} -gt 0 ]]; then
  echo "WARN: Orphan files (not in tools.json): ${orphans[*]}"
  ((warnings++))
else
  echo "✓ No orphan tool files"
fi

# --- 6. Individual files have correct structure and match tools.json ---
structure_errors=0
data_mismatches=0
for slug in "${slugs[@]}"; do
  file="$TOOLS_DIR/$slug.json"
  [[ ! -f "$file" ]] && continue

  # Check top-level structure
  has_meta=$(jq 'has("meta")' "$file")
  has_tool=$(jq 'has("tool")' "$file")
  if [[ "$has_meta" != "true" || "$has_tool" != "true" ]]; then
    echo "FAIL: $slug.json missing meta/tool wrapper (got keys: $(jq -c 'keys' "$file"))"
    ((structure_errors++))
    continue
  fi

  # Check meta.tool_count matches
  file_count=$(jq '.meta.tool_count' "$file")
  if [[ "$file_count" != "$actual" ]]; then
    echo "FAIL: $slug.json meta.tool_count ($file_count) != tools.json ($actual)"
    ((structure_errors++))
  fi

  # Check meta.source matches
  main_source=$(jq -r '.meta.source' "$TOOLS_JSON")
  file_source=$(jq -r '.meta.source' "$file")
  if [[ "$file_source" != "$main_source" ]]; then
    echo "FAIL: $slug.json meta.source ($file_source) != tools.json ($main_source)"
    ((structure_errors++))
  fi

  # Check tool data matches tools.json
  expected=$(jq -c --arg s "$slug" '.tools[] | select(.slug == $s)' "$TOOLS_JSON")
  got=$(jq -c '.tool' "$file")
  if [[ "$expected" != "$got" ]]; then
    echo "FAIL: $slug.json tool data differs from tools.json"
    ((data_mismatches++))
  fi
done

if [[ $structure_errors -gt 0 ]]; then
  echo "FAIL: $structure_errors file(s) with structure errors"
  ((errors += structure_errors))
else
  echo "✓ All individual files have correct meta/tool structure"
fi

if [[ $data_mismatches -gt 0 ]]; then
  echo "FAIL: $data_mismatches file(s) with data mismatches (run generate-tool-files.sh to fix)"
  ((errors += data_mismatches))
else
  echo "✓ All individual files match tools.json data"
fi

# --- 7. changelog.json is valid ---
if ! jq empty "$CHANGELOG" 2>/dev/null; then
  echo "FAIL: changelog.json is not valid JSON"
  ((errors++))
else
  echo "✓ changelog.json is valid JSON"
fi

# --- 8. Every pricing_url is non-empty ---
empty_urls=$(jq -r '.tools[] | select(.vendor.pricing_url == "" or .vendor.pricing_url == null) | .slug' "$TOOLS_JSON")
if [[ -n "$empty_urls" ]]; then
  echo "WARN: Tools with empty pricing_url: $empty_urls"
  ((warnings++))
else
  echo "✓ All tools have pricing URLs"
fi

# --- Summary ---
echo ""
echo "=== Results ==="
if [[ $errors -eq 0 && $warnings -eq 0 ]]; then
  echo "ALL CHECKS PASSED ✓"
elif [[ $errors -eq 0 ]]; then
  echo "PASSED with $warnings warning(s)"
else
  echo "FAILED: $errors error(s), $warnings warning(s)"
  echo ""
  echo "To fix structure/data issues: ./scripts/generate-tool-files.sh"
  exit 1
fi
