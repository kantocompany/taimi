#!/usr/bin/env bash
# Save a verbatim markdown render of a tool's vendor.pricing_url to
# fetched/<slug>.md via the r.jina.ai rendering proxy, for research agents to
# Read. WebFetch only returns a model summary of a page; agents need page text
# to quote plan cards. The harness fetches (not the agent), so agents gain no
# shell or network capability.
#
# Pages named with a full https:// URL in verification_override are rendered
# too, to fetched/<slug>__<url>.md (at most 6; an r.jina.ai/ prefix is dropped
# and pricing_url is not repeated). Pages written without https:// are not.
#
# Never fatal: on any failure the file is absent and agents fall back to WebFetch.
#
# Usage: ./scripts/fetch-render.sh <slug>
set -uo pipefail

slug="$1"
data="data/tools/${slug}.json"
out="fetched/${slug}.md"
mkdir -p fetched
rm -f "$out" "$out.tmp" "fetched/${slug}__"*.md

# render <url> <out-file>
render() {
  if curl -sS --fail --max-time 60 -o "$2.tmp" -- "https://r.jina.ai/$1" && [[ -s "$2.tmp" ]]; then
    mv "$2.tmp" "$2"
    echo "  [$slug] raw render: $2 ($(wc -c < "$2" | tr -d ' ') bytes)"
  else
    rm -f "$2.tmp"
    echo "  [$slug] raw render failed: $1 — agents fall back to WebFetch"
  fi
}

url=$(jq -r '.vendor.pricing_url // empty' "$data" 2>/dev/null)
if [[ "$url" == https://* ]]; then
  render "$url" "$out"
else
  echo "  [$slug] no https pricing_url — skipping raw render"
fi

# Override pages, one "url<TAB>file-name" line each
jq -r '
  (.vendor.pricing_url // "" | sub("/$"; "")) as $own
  | [.verification_override // "" | scan("https://[^\\s]+")
      | sub("^https://r\\.jina\\.ai/"; "") | sub("[.,;:)]+$"; "")
      | select(startswith("https://") and sub("/$"; "") != $own)]
  | unique | .[:6][]
  | "\(.)\t\(sub("^https://"; "") | gsub("[^A-Za-z0-9.-]"; "_") | sub("_+$"; "") | .[:100])"
' "$data" 2>/dev/null | while IFS=$'\t' read -r page name; do
  render "$page" "fetched/${slug}__${name}.md"
done
exit 0
