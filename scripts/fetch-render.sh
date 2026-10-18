#!/usr/bin/env bash
# Save a verbatim markdown render of a tool's vendor.pricing_url to
# fetched/<slug>.md via the r.jina.ai rendering proxy, for research agents to
# Read. WebFetch only returns a model summary of a page; agents need page text
# to quote plan cards. The harness fetches (not the agent), so agents gain no
# shell or network capability.
#
# Never fatal: on any failure the file is absent and agents fall back to WebFetch.
#
# Usage: ./scripts/fetch-render.sh <slug>
set -uo pipefail

slug="$1"
out="fetched/${slug}.md"
mkdir -p fetched
rm -f "$out" "$out.tmp"

url=$(jq -r '.vendor.pricing_url // empty' "data/tools/${slug}.json" 2>/dev/null)
if [[ "$url" != https://* ]]; then
  echo "  [$slug] no https pricing_url — skipping raw render"
  exit 0
fi

if curl -sS --fail --max-time 60 -o "$out.tmp" -- "https://r.jina.ai/${url}" && [[ -s "$out.tmp" ]]; then
  mv "$out.tmp" "$out"
  echo "  [$slug] raw render: $out ($(wc -c < "$out" | tr -d ' ') bytes)"
else
  rm -f "$out.tmp"
  echo "  [$slug] raw render failed — agents fall back to WebFetch"
fi
exit 0
