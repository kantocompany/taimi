#!/usr/bin/env bash
set -euo pipefail

# Validate consistency across all Taimi data files.
# Source of truth: data/tools/*.json (individual tool objects)
# Derived: public/v1/tools.json, public/v1/tools/*.json, public/index.html
#
# Run at the end of every update cycle before committing.
# Usage: ./scripts/validate.sh

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="$REPO_ROOT/data/tools"
OBSERVATIONS="$REPO_ROOT/data/observations.html"
TOOLS_JSON="$REPO_ROOT/public/v1/tools.json"
CHANGELOG="$REPO_ROOT/public/v1/changelog.json"
API_DIR="$REPO_ROOT/public/v1/tools"
INDEX_HTML="$REPO_ROOT/public/index.html"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }

errors=0
warnings=0

echo "=== Taimi Data Validation ==="
echo ""

# --- 1. Source files exist and are valid JSON ---
shopt -s nullglob
source_files=("$DATA_DIR"/*.json)
shopt -u nullglob

if [[ ${#source_files[@]} -eq 0 ]]; then
  echo "FAIL: No JSON files in $DATA_DIR"
  exit 1
fi

invalid=0
for f in "${source_files[@]}"; do
  if ! jq empty "$f" 2>/dev/null; then
    echo "FAIL: $(basename "$f") is not valid JSON"
    ((invalid++)) || true
  fi
done
if [[ $invalid -gt 0 ]]; then
  echo "FAIL: $invalid source file(s) with invalid JSON"
  exit 1
fi
echo "✓ All ${#source_files[@]} source files are valid JSON"

# --- 1b. Tool cap ---
MAX_TOOLS=12
if [[ ${#source_files[@]} -gt $MAX_TOOLS ]]; then
  echo "FAIL: Tool cap exceeded: ${#source_files[@]} tools (max $MAX_TOOLS)"
  ((errors++)) || true
else
  echo "✓ Tool count within cap (${#source_files[@]}/$MAX_TOOLS)"
fi

# --- 2. No duplicate slugs in source files ---
dupes=$(for f in "${source_files[@]}"; do jq -r '.slug' "$f"; done | sort | uniq -d)
if [[ -n "$dupes" ]]; then
  echo "FAIL: Duplicate slugs: $dupes"
  ((errors++)) || true
else
  echo "✓ No duplicate slugs"
fi

# --- 3. Every source file has required fields ---
schema_errors=0
for f in "${source_files[@]}"; do
  slug=$(jq -r '.slug // empty' "$f")
  name=$(jq -r '.name // empty' "$f")
  vendor_url=$(jq -r '.vendor.pricing_url // empty' "$f")

  if [[ -z "$slug" ]]; then
    echo "FAIL: $(basename "$f") missing .slug"
    ((schema_errors++)) || true
  fi
  if [[ -z "$name" ]]; then
    echo "FAIL: $(basename "$f") missing .name"
    ((schema_errors++)) || true
  fi
  if [[ -z "$vendor_url" ]]; then
    echo "WARN: $(basename "$f") missing .vendor.pricing_url"
    ((warnings++)) || true
  fi
done
if [[ $schema_errors -gt 0 ]]; then
  ((errors += schema_errors))
else
  echo "✓ All source files have required fields"
fi

# --- 3a. Plan-level structural completeness ---
# A null plan name renders a blank tier label; a null category silently drops
# the plan from every index.html column (2026-06-14 kiro/augment incident).
# Backstop behind the apply-gate identity guard — catches any other vector.
plan_offenders=$(for f in "${source_files[@]}"; do
  jq -r '
    .slug as $slug
    | .plans[]?
    | . as $p
    | ("id", "name", "category") as $field
    | select(($p[$field] // "") == "")
    | "\($slug)/\($p.id // "?"): null or empty .\($field)"
  ' "$f"
done)
if [[ -n "$plan_offenders" ]]; then
  echo "FAIL: plans missing id, name, or category (ships as a visible site defect):"
  echo "$plan_offenders" | sed 's/^/  /'
  ((errors++)) || true
else
  echo "✓ All plans have id, name, and category"
fi

# --- 3b. Notes must not duplicate structured fields (Fix 6a regression guard) ---
# Fires only when overage.notes carries a "$N/<word>" fragment whose <word> matches the
# structured overage.unit AND whose number equals a structured rate (price_per_unit or
# input/output_per_million). Non-matching unit words (session-hour, container-hour, search,
# effort) never fire, so unit-carrier prose is left untouched.
dup_offenders=$(for f in "${source_files[@]}"; do
  jq -r '
    def unit_words(u):
      if u == "request" then ["req","request"]
      elif u == "token" then ["token","tokens"]
      elif u == "acu" then ["acu","acus","credit","credits"]
      else [] end;
    .slug as $slug
    | .plans[]?
    | select(.overage != null and (.overage.notes // null) != null)
    | . as $p | $p.overage as $ov
    | (unit_words($ov.unit)) as $words
    | ([$ov.price_per_unit, $ov.input_per_million, $ov.output_per_million] | map(select(. != null))) as $nums
    | ($ov.notes | [scan("\\$([0-9]+(?:\\.[0-9]+)?)/([a-zA-Z]+)")])[] as $frag
    | select(($words | index(($frag[1] | ascii_downcase))) != null
             and ($nums | index(($frag[0] | tonumber))) != null)
    | "\($slug)/\($p.id): $\($frag[0])/\($frag[1])"
  ' "$f"
done)
# Also guard includes.notes from restating the structured premium_requests count
# (the page renders it via the helper in generate-index.sh). Fires only when the
# plan has a structured premium_requests value, so notes-as-sole-carrier is safe.
preq_offenders=$(for f in "${source_files[@]}"; do
  jq -r '
    .slug as $slug
    | .plans[]?
    | select(.includes.premium_requests != null)
    | select((.includes.notes // "") | test("[0-9][0-9,]*K? *premium req"; "i"))
    | "\($slug)/\(.id): includes.notes restates premium_requests count"
  ' "$f"
done)
if [[ -n "$dup_offenders" || -n "$preq_offenders" ]]; then
  echo "FAIL: notes duplicate a structured field (rate in overage.*, or count in premium_requests):"
  [[ -n "$dup_offenders" ]] && echo "$dup_offenders" | sed 's/^/  /'
  [[ -n "$preq_offenders" ]] && echo "$preq_offenders" | sed 's/^/  /'
  ((errors++)) || true
else
  echo "✓ No notes duplicate structured fields"
fi

# --- 3c. Surface _pending conditional-hold markers (operator visibility) ---
# A deferred "revisit when vendor publishes X" decision encoded as source-only
# data state. Re-presented every cycle so the open decision never goes silent.
pending_markers=$(for f in "${source_files[@]}"; do
  jq -r '.slug as $s | .plans[]? | select(._pending != null) | "  \($s)/\(.id): \(._pending)"' "$f"
done)
if [[ -n "$pending_markers" ]]; then
  echo "NOTE: plans carrying a _pending conditional-hold marker (re-evaluate this cycle):"
  echo "$pending_markers"
  pending_count=$(printf '%s\n' "$pending_markers" | grep -c .)
  ((warnings += pending_count)) || true
else
  echo "✓ No _pending conditional-hold markers"
fi

# --- 4. Observations file exists ---
if [[ ! -f "$OBSERVATIONS" ]]; then
  echo "FAIL: $OBSERVATIONS not found"
  ((errors++)) || true
else
  echo "✓ Observations file exists"
fi

# --- 5. tools.json exists and is valid ---
if [[ ! -f "$TOOLS_JSON" ]]; then
  echo "FAIL: $TOOLS_JSON not found (run scripts/assemble.sh)"
  ((errors++)) || true
else
  if ! jq empty "$TOOLS_JSON" 2>/dev/null; then
    echo "FAIL: tools.json is not valid JSON"
    ((errors++)) || true
  else
    echo "✓ tools.json is valid JSON"

    # tool_count matches source file count
    declared=$(jq '.meta.tool_count' "$TOOLS_JSON")
    if [[ "$declared" != "${#source_files[@]}" ]]; then
      echo "FAIL: tools.json tool_count ($declared) != source file count (${#source_files[@]})"
      ((errors++)) || true
    else
      echo "✓ tool_count matches (${#source_files[@]} tools)"
    fi

    # Every source tool is in tools.json
    source_mismatches=0
    for f in "${source_files[@]}"; do
      slug=$(jq -r '.slug' "$f")
      source_data=$(jq -c 'del(.verification_override, ._notes_first_pass, ._capabilities_first_pass) | .plans = (.plans | map(del(._last_seen_on_page, ._pending)))' "$f")
      assembled_data=$(jq -c --arg s "$slug" '.tools[] | select(.slug == $s)' "$TOOLS_JSON")
      if [[ "$source_data" != "$assembled_data" ]]; then
        echo "FAIL: $slug data in tools.json differs from source (run scripts/assemble.sh)"
        ((source_mismatches++)) || true
      fi
    done
    if [[ $source_mismatches -gt 0 ]]; then
      ((errors += source_mismatches))
    else
      echo "✓ All tools in tools.json match source data"
    fi
  fi
fi

# --- 6. Individual API files match tools.json ---
if [[ -f "$TOOLS_JSON" ]]; then
  api_errors=0
  for f in "${source_files[@]}"; do
    slug=$(jq -r '.slug' "$f")
    api_file="$API_DIR/$slug.json"
    if [[ ! -f "$api_file" ]]; then
      echo "FAIL: Missing API file: $api_file"
      ((api_errors++)) || true
      continue
    fi
    # Check structure
    if [[ "$(jq 'has("meta") and has("tool")' "$api_file")" != "true" ]]; then
      echo "FAIL: $slug.json missing meta/tool wrapper"
      ((api_errors++)) || true
      continue
    fi
    # Check tool data matches source
    api_tool=$(jq -c '.tool' "$api_file")
    source_data=$(jq -c 'del(.verification_override, ._notes_first_pass, ._capabilities_first_pass) | .plans = (.plans | map(del(._last_seen_on_page, ._pending)))' "$f")
    if [[ "$api_tool" != "$source_data" ]]; then
      echo "FAIL: $slug.json API file tool data differs from source"
      ((api_errors++)) || true
    fi
  done
  # Check for orphan API files
  for api_file in "$API_DIR"/*.json; do
    [[ ! -f "$api_file" ]] && continue
    fname=$(basename "$api_file" .json)
    if [[ ! -f "$DATA_DIR/$fname.json" ]]; then
      echo "WARN: Orphan API file (no source): $fname.json"
      ((warnings++)) || true
    fi
  done
  if [[ $api_errors -gt 0 ]]; then
    ((errors += api_errors))
  else
    echo "✓ All API files match source data"
  fi
fi

# --- 7. changelog.json is valid ---
if [[ ! -f "$CHANGELOG" ]]; then
  echo "WARN: changelog.json not found"
  ((warnings++)) || true
elif ! jq empty "$CHANGELOG" 2>/dev/null; then
  echo "FAIL: changelog.json is not valid JSON"
  ((errors++)) || true
else
  echo "✓ changelog.json is valid JSON"
fi

# --- 8. index.html exists ---
if [[ ! -f "$INDEX_HTML" ]]; then
  echo "FAIL: index.html not found (run scripts/generate-index.sh)"
  ((errors++)) || true
else
  echo "✓ index.html exists"
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
  echo "To fix: run ./scripts/assemble.sh && ./scripts/generate-index.sh"
  exit 1
fi
