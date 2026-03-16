#!/usr/bin/env bash
set -euo pipefail

# Generate public/index.html from public/v1/tools.json (single source of truth).
# Static parts (CSS, banners, observations, footer, JS) live in this script.
# Tool rows are generated dynamically from JSON data.
#
# Usage: ./scripts/generate-index.sh

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_JSON="$REPO_ROOT/public/v1/tools.json"
OBSERVATIONS="$REPO_ROOT/data/observations.html"
OUTPUT="$REPO_ROOT/public/index.html"

if [[ ! -f "$TOOLS_JSON" ]]; then
  echo "ERROR: $TOOLS_JSON not found" >&2
  exit 1
fi

if [[ ! -f "$OBSERVATIONS" ]]; then
  echo "ERROR: $OBSERVATIONS not found" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }

# Extract metadata for header
tool_count=$(jq '.meta.tool_count' "$TOOLS_JSON")
updated_at=$(jq -r '.meta.updated_at' "$TOOLS_JSON")
# Format: "13 March 2026" from ISO date
updated_display=$(date -d "${updated_at}" '+%-d %B %Y' 2>/dev/null || date -jf '%Y-%m-%dT%H:%M:%SZ' "${updated_at}" '+%-d %B %Y' 2>/dev/null || echo "${updated_at:8:2} ${updated_at:0:7}")
# Month/year for description meta tag
updated_month=$(date -d "${updated_at}" '+%B %Y' 2>/dev/null || date -jf '%Y-%m-%dT%H:%M:%SZ' "${updated_at}" '+%B %Y' 2>/dev/null || echo "${updated_at:0:7}")

# Collect tool names for meta description
tool_names=$(jq -r '[.tools[].name] | join(", ")' "$TOOLS_JSON")

# --- Generate tool rows via jq ---
# This jq filter produces one HTML row per tool.
# It groups plans by category and computes data-* sort attributes.
generate_rows() {
  jq -r '
    # Helper: format price for display (strip trailing .00)
    def format_price:
      if . == null then ""
      elif . == 0 then "$0"
      elif (. == (. | floor)) then "$\(. | floor)"
      else "$\(.)"
      end;

    # Helper: format number for sort attributes (strip trailing .00)
    def sort_num:
      if . == (. | floor) then (. | floor | tostring)
      else tostring
      end;

    # Helper: format price with period
    def price_display:
      if .base_price == null then ""
      elif .base_price.amount == 0 then ""
      elif .base_price.per == "team" or .base_price.per == "flat" then
        "\(.base_price.amount | format_price)/mo flat"
      elif .base_price.per == "user" then
        "\(.base_price.amount | format_price)/mo"
      else
        "\(.base_price.amount | format_price)/\(.base_price.per)"
      end;

    # Helper: format price with /seat for team plans
    def price_display_team:
      if .base_price == null then ""
      elif .base_price.per == "team" or .base_price.per == "flat" then
        "\(.base_price.amount | format_price)/mo flat"
      else
        "\(.base_price.amount | format_price)/seat"
      end;

    # Helper: get flag emoji for a tool
    def country_flag:
      if .vendor.eu_based then "🇪🇺"
      elif .vendor.hq_country == "US" then "🇺🇸"
      elif .vendor.hq_country == "UK" then "🇬🇧"
      elif .vendor.hq_country == "DE" then "🇩🇪"
      elif .vendor.hq_country == "FR" then "🇫🇷"
      elif .vendor.hq_country == null or .vendor.hq_country == "" then "🌐"
      else "🌐"
      end;

    # Helper: compute data-* sort value for a category
    def sort_val(cat):
      [.plans[] | select(.category == cat) | .base_price.amount // 9999] | min // 9999;

    # Helper: check if enterprise plan exists
    def has_enterprise:
      [.plans[] | select(.category == "enterprise")] | length > 0;

    # Helper: render a single price block
    def render_price_block(cat):
      . as $plan |
      .base_price as $bp |
      (if cat == "free" then "pb-free"
       elif cat == "individual" then "pb-individual"
       elif cat == "team" then "pb-team"
       elif cat == "usage" then "pb-usage"
       elif cat == "enterprise" then "pb-enterprise"
       else "pb-free" end) as $class |
      (if cat == "team" then ($plan | price_display_team) else ($plan | price_display) end) as $price |
      (if $plan.platform_plan == true then "<span class=\"platform-badge\">P</span>" else "" end) as $badge |
      (if $plan.includes.notes then $plan.includes.notes else "" end) as $notes |

      if cat == "free" then
        "          <a class=\"price-block \($class)\" href=\"\($plan._pricing_url)\" target=\"_blank\" rel=\"noopener\"><div class=\"tier-name\">\($plan.name)\($badge)</div>\(if $notes != "" then "<div class=\"tier-notes\">\($notes)</div>" else "" end)</a>"
      elif cat == "enterprise" then
        (if $plan.includes.notes then $plan.includes.notes else $plan.name end) as $ent_text |
        "          <a class=\"price-block \($class)\" href=\"\($plan._pricing_url)\" target=\"_blank\" rel=\"noopener\"><span class=\"tier-name\">\($ent_text)</span></a>"
      elif cat == "usage" then
        (if $plan.overage then
          ($plan.overage.notes // "") as $ovnotes |
          (if $plan.overage.unit == "token" then
            (if $plan.overage.input_per_million != null and $plan.overage.output_per_million != null then
              "\($plan.overage.input_per_million | format_price)/\($plan.overage.output_per_million | format_price)/M"
            else
              ($ovnotes | split(" ") | first // "varied")
            end)
          elif $plan.overage.unit == "request" then
            (if $plan.overage.price_per_unit != null then "$\($plan.overage.price_per_unit)/req"
            else "Effort-based" end)
          elif $plan.overage.unit == "acu" then
            (if $plan.overage.price_per_unit != null then "$\($plan.overage.price_per_unit)/unit"
            else "varied" end)
          else "varied" end) as $usage_price |
          (if $plan.overage.unit == "token" then "per M tokens"
           elif $plan.overage.unit == "request" then "per request"
           elif $plan.overage.unit == "acu" then "per ACU (~minutes)"
           else "varies by provider" end) as $unit_text |
          "          <a class=\"price-block \($class)\" href=\"\($plan._pricing_url)\" target=\"_blank\" rel=\"noopener\"><div class=\"tier-row\"><span class=\"tier-name\">\($plan.name)\($badge)</span><span class=\"tier-price\">\($usage_price)</span></div>\(if $ovnotes != "" then "<div class=\"tier-notes\">\($ovnotes)</div>" else "" end)<div class=\"tier-unit\">\($unit_text)</div></a>"
        else
          "          <a class=\"price-block \($class)\" href=\"\($plan._pricing_url)\" target=\"_blank\" rel=\"noopener\"><div class=\"tier-row\"><span class=\"tier-name\">\($plan.name)\($badge)</span><span class=\"tier-price\">Your API costs</span></div><div class=\"tier-notes\">Any LLM provider</div><div class=\"tier-unit\">varies by provider</div></a>"
        end)
      else
        "          <a class=\"price-block \($class)\" href=\"\($plan._pricing_url)\" target=\"_blank\" rel=\"noopener\"><div class=\"tier-row\"><span class=\"tier-name\">\($plan.name)\($badge)</span><span class=\"tier-price\">\($price)</span></div>\(if $notes != "" then "<div class=\"tier-notes\">\($notes)</div>" else "" end)</a>"
      end;

    .tools[] |
    . as $tool |

    # Inject pricing_url into each plan for link generation
    ($tool.vendor.pricing_url) as $default_url |
    ($tool.plans | map(. + { _pricing_url: $default_url })) as $plans |
    ($tool + { plans: $plans }) as $tool |

    # Compute sort values
    ($tool | sort_val("free")) as $sort_free |
    ($tool | sort_val("individual")) as $sort_individual |
    ($tool | sort_val("team")) as $sort_team |
    (if ($tool | has_enterprise) then 1 else 0 end) as $sort_enterprise |
    (if $tool.vendor.eu_based then 1 else 0 end) as $sort_eu |

    # EU vendor class
    (if $tool.vendor.eu_based then " eu-vendor" else "" end) as $eu_class |

    # Start row
    "        <!-- ============ \($tool.name) ============ -->",
    "        <div class=\"row\($eu_class)\" data-name=\"\($tool.slug)\" data-individual=\"\($sort_individual | sort_num)\" data-team=\"\($sort_team | sort_num)\" data-free=\"\($sort_free | sort_num)\" data-enterprise=\"\($sort_enterprise)\" data-eu=\"\($sort_eu)\">",

    # Vendor cell
    "        <div class=\"vendor-cell\">",
    "          <div class=\"vendor-name\"><span class=\"flag\">\($tool | country_flag)</span><span class=\"name\">\($tool.name)</span></div>",
    "          <div class=\"vendor-parent\">\($tool.vendor.name)</div>",
    (if $tool.vendor.eu_based then
      "          <div class=\"vendor-eu-badge\">EU-based vendor</div>"
    else "" end),
    "          <a class=\"vendor-link\" href=\"\($tool.vendor.pricing_url)\" target=\"_blank\" rel=\"noopener\">↗ official pricing</a>",
    "        </div>",

    # Free tier cell
    ([$tool.plans[] | select(.category == "free")] | if length == 0 then
      "        <div class=\"cell\"><div class=\"empty-cell\">—</div></div>"
    else
      "        <div class=\"cell\">",
      (.[] | render_price_block("free")),
      "        </div>"
    end),

    # Individual cell
    ([$tool.plans[] | select(.category == "individual")] | if length == 0 then
      "        <div class=\"cell\"><div class=\"empty-cell\">—</div></div>"
    else
      "        <div class=\"cell\">",
      (.[] | render_price_block("individual")),
      "        </div>"
    end),

    # Team cell
    ([$tool.plans[] | select(.category == "team")] | if length == 0 then
      "        <div class=\"cell\"><div class=\"empty-cell\">—</div></div>"
    else
      "        <div class=\"cell\">",
      (.[] | render_price_block("team")),
      "        </div>"
    end),

    # Usage cell
    ([$tool.plans[] | select(.category == "usage")] | if length == 0 then
      "        <div class=\"cell\"><div class=\"empty-cell\">—</div></div>"
    else
      "        <div class=\"cell\">",
      (.[] | render_price_block("usage")),
      "        </div>"
    end),

    # Enterprise cell
    ([$tool.plans[] | select(.category == "enterprise")] | if length == 0 then
      "        <div class=\"cell\"><div class=\"empty-cell\">—</div></div>"
    else
      "        <div class=\"cell\">",
      (.[] | render_price_block("enterprise")),
      "        </div>"
    end),

    # Close row
    "        </div>",
    ""
  ' "$TOOLS_JSON"
}

# --- Write output ---
{
# ==================== HEAD ====================
cat << 'HEADEOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
HEADEOF

echo "  <title>Taimi — The AI Market Intelligence | Agentic Coding Tool Pricing | Kanto Company</title>"
echo "  <meta name=\"description\" content=\"Live pricing comparison of agentic AI coding tools. ${tool_names}. Updated ${updated_month}.\">"

cat << 'CSSEOF'
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Space+Mono:wght@400;700&family=DM+Sans:wght@400;500;600;700&display=swap" rel="stylesheet">
  <style>
    :root {
      --kanto-lime: #AAFF00;
      --kanto-lime-dim: rgba(170, 255, 0, 0.15);
      --kanto-lime-border: rgba(170, 255, 0, 0.3);
      --kanto-dark: #111114;
      --kanto-surface: #1a1a1e;
      --kanto-surface-hover: #222228;
      --kanto-border: rgba(255,255,255,0.09);
      --kanto-text: #ececec;
      --kanto-text-dim: #999;
      --kanto-text-muted: #707070;
      --col-free: #4ade80;
      --col-individual: #a78bfa;
      --col-team: #fbbf24;
      --col-usage: #f472b6;
      --col-enterprise: #c084fc;
      --col-eu: var(--kanto-lime);
    }

    * { margin: 0; padding: 0; box-sizing: border-box; }

    body {
      background: var(--kanto-dark);
      color: var(--kanto-text);
      font-family: 'DM Sans', -apple-system, BlinkMacSystemFont, sans-serif;
      line-height: 1.5;
      -webkit-font-smoothing: antialiased;
    }

    .container {
      max-width: 1360px;
      margin: 0 auto;
      padding: 40px 24px 60px;
    }

    /* Header */
    .header {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      margin-bottom: 36px;
      flex-wrap: wrap;
      gap: 16px;
    }
    .header-left h1 {
      font-family: 'Space Mono', monospace;
      font-size: 24px;
      font-weight: 700;
      color: #fff;
      letter-spacing: -0.03em;
    }
    .header-left h1 span {
      color: var(--kanto-lime);
    }
    .header-left p {
      font-size: 13px;
      color: var(--kanto-text-dim);
      margin-top: 6px;
    }
    .header-right {
      display: flex;
      align-items: center;
      gap: 8px;
      font-size: 12px;
      color: var(--kanto-text-muted);
    }
    .header-right a {
      color: var(--kanto-lime);
      text-decoration: none;
      font-weight: 600;
      font-size: 12px;
      padding: 6px 14px;
      border: 1px solid var(--kanto-lime-border);
      border-radius: 4px;
      transition: all 0.15s;
    }
    .header-right a:hover {
      background: var(--kanto-lime-dim);
    }

    /* Warning banner */
    .warning {
      padding: 10px 16px;
      background: rgba(244, 114, 182, 0.06);
      border: 1px solid rgba(244, 114, 182, 0.15);
      border-radius: 6px;
      font-size: 12px;
      color: #f9a8d4;
      margin-bottom: 20px;
      line-height: 1.6;
    }
    .warning strong { color: #fbb6ce; }

    .warning-platform {
      padding: 10px 16px;
      background: rgba(251, 191, 36, 0.06);
      border: 1px solid rgba(251, 191, 36, 0.15);
      border-radius: 6px;
      font-size: 12px;
      color: #fcd34d;
      margin-bottom: 20px;
      line-height: 1.6;
    }
    .warning-platform strong { color: #fde68a; }

    .platform-badge {
      font-size: 8px;
      font-weight: 700;
      color: #fcd34d;
      vertical-align: super;
      letter-spacing: 0.03em;
      margin-left: 3px;
      opacity: 0.7;
    }

    /* Matrix */
    .matrix {
      width: 100%;
      overflow-x: auto;
      -webkit-overflow-scrolling: touch;
    }
    .matrix-grid {
      display: grid;
      grid-template-columns: 200px repeat(5, 1fr);
      gap: 8px;
      min-width: 1100px;
    }

    /* Column headers */
    .col-header {
      font-family: 'Space Mono', monospace;
      font-size: 10px;
      text-transform: uppercase;
      letter-spacing: 0.1em;
      padding: 0 6px 14px;
      font-weight: 700;
      border-bottom: 1px solid var(--kanto-border);
    }
    .col-header.h-vendor { color: var(--kanto-text-muted); }
    .col-header.h-free { color: var(--col-free); }
    .col-header.h-individual { color: var(--col-individual); }
    .col-header.h-team { color: var(--col-team); }
    .col-header.h-usage { color: var(--col-usage); }
    .col-header.h-enterprise { color: var(--col-enterprise); }

    /* Row */
    .row {
      display: contents;
    }
    .row > div {
      padding: 17px 0;
      border-bottom: 1px solid var(--kanto-border);
      transition: background 0.12s;
    }
    .row:hover > div {
      background: var(--kanto-surface);
    }
    .row.eu-vendor > div {
      border-left: none;
    }
    .row.eu-vendor > .vendor-cell {
      border-left: 2px solid var(--kanto-lime-border);
      padding-left: 10px;
    }

    /* Vendor cell */
    .vendor-cell {
      display: flex;
      flex-direction: column;
      justify-content: flex-start;
      padding-right: 12px;
    }
    .vendor-name {
      display: flex;
      align-items: center;
      gap: 7px;
    }
    .vendor-name .flag { font-size: 15px; }
    .vendor-name .name {
      font-family: 'Space Mono', monospace;
      font-size: 13px;
      font-weight: 700;
      color: #fff;
    }
    .vendor-parent {
      font-size: 10px;
      color: var(--kanto-text-muted);
      margin-top: 2px;
      padding-left: 24px;
    }
    .vendor-eu-badge {
      font-size: 9px;
      color: var(--kanto-lime);
      text-transform: uppercase;
      letter-spacing: 0.06em;
      font-weight: 700;
      margin-top: 3px;
      padding-left: 24px;
    }
    .vendor-link {
      font-size: 10px;
      color: #6366f1;
      text-decoration: none;
      padding-left: 24px;
      margin-top: 3px;
      opacity: 0.7;
      transition: opacity 0.12s;
    }
    .vendor-link:hover { opacity: 1; }

    /* Cells */
    .cell {
      display: flex;
      flex-direction: column;
      gap: 6px;
      padding-left: 4px;
      padding-right: 4px;
    }

    /* Price block - clickable */
    .price-block {
      display: block;
      text-decoration: none;
      padding: 7px 10px;
      border-radius: 5px;
      font-size: 12px;
      line-height: 1.4;
      transition: all 0.12s;
      cursor: pointer;
    }
    .price-block:hover {
      filter: brightness(1.3);
      transform: translateY(-1px);
    }
    .price-block .tier-row {
      display: flex;
      justify-content: space-between;
      align-items: baseline;
      gap: 6px;
    }
    .price-block .tier-name {
      font-size: 10px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.03em;
      color: var(--kanto-text);
    }
    .price-block .tier-price {
      font-family: 'Space Mono', monospace;
      font-size: 12px;
      font-weight: 700;
      white-space: nowrap;
    }
    .price-block .tier-notes {
      font-size: 10px;
      color: var(--kanto-text-dim);
      margin-top: 1px;
    }
    .price-block .tier-unit {
      font-size: 9px;
      color: var(--kanto-text-muted);
      font-style: italic;
      margin-top: 1px;
    }

    /* Color variants */
    .pb-free {
      background: rgba(74, 222, 128, 0.08);
      border: 1px solid rgba(74, 222, 128, 0.2);
    }
    .pb-free .tier-price, .pb-free .tier-name { color: var(--col-free); }

    .pb-individual {
      background: rgba(167, 139, 250, 0.08);
      border: 1px solid rgba(167, 139, 250, 0.2);
    }
    .pb-individual .tier-price { color: var(--col-individual); }

    .pb-team {
      background: rgba(251, 191, 36, 0.08);
      border: 1px solid rgba(251, 191, 36, 0.2);
    }
    .pb-team .tier-price { color: var(--col-team); }

    .pb-usage {
      background: rgba(244, 114, 182, 0.08);
      border: 1px solid rgba(244, 114, 182, 0.2);
    }
    .pb-usage .tier-price { color: var(--col-usage); }

    .pb-enterprise {
      background: rgba(192, 132, 252, 0.08);
      border: 1px solid rgba(192, 132, 252, 0.2);
    }
    .pb-enterprise .tier-name { color: var(--col-enterprise); }

    .pb-enterprise-no {
      background: rgba(80, 80, 80, 0.05);
      border: 1px dashed rgba(120, 120, 120, 0.2);
    }
    .pb-enterprise-no .tier-name { color: var(--kanto-text-muted); }

    /* Empty cell */
    .empty-cell {
      padding: 10px;
      border-radius: 5px;
      background: rgba(50, 50, 55, 0.2);
      border: 1px dashed rgba(80, 80, 85, 0.3);
      min-height: 44px;
      display: flex;
      align-items: center;
      justify-content: center;
      color: var(--kanto-text-muted);
      font-size: 11px;
      font-style: italic;
    }

    /* Footer observations */
    .observations {
      margin-top: 32px;
      padding: 20px 24px;
      background: var(--kanto-surface);
      border-radius: 8px;
      border: 1px solid var(--kanto-border);
    }
    .observations h3 {
      font-family: 'Space Mono', monospace;
      font-size: 11px;
      font-weight: 700;
      color: var(--kanto-text-dim);
      text-transform: uppercase;
      letter-spacing: 0.06em;
      margin-bottom: 12px;
    }
    .observations ul {
      list-style: none;
      padding: 0;
    }
    .observations li {
      font-size: 12px;
      color: var(--kanto-text-dim);
      line-height: 1.9;
      padding-left: 18px;
      position: relative;
    }
    .observations li::before {
      content: '●';
      position: absolute;
      left: 0;
      font-size: 8px;
      top: 2px;
    }
    .observations li:nth-child(1)::before { color: var(--col-free); }
    .observations li:nth-child(2)::before { color: var(--col-team); }
    .observations li:nth-child(3)::before { color: var(--col-usage); }
    .observations li:nth-child(4)::before { color: var(--kanto-lime); }
    .observations li:nth-child(5)::before { color: var(--col-individual); }
    .observations li:nth-child(6)::before { color: var(--col-free); }
    .observations li strong { color: var(--kanto-text); }

    /* Site footer */
    .site-footer {
      margin-top: 48px;
      padding-top: 24px;
      border-top: 1px solid var(--kanto-border);
      display: flex;
      justify-content: space-between;
      align-items: center;
      flex-wrap: wrap;
      gap: 12px;
    }
    .site-footer .left {
      font-size: 12px;
      color: var(--kanto-text-muted);
    }
    .site-footer .left a {
      color: var(--kanto-lime);
      text-decoration: none;
      font-weight: 600;
    }
    .site-footer .right {
      font-size: 11px;
      color: var(--kanto-text-muted);
    }

    /* Mobile scroll hint */
    @media (max-width: 1200px) {
      .scroll-hint {
        display: block;
        text-align: center;
        font-size: 11px;
        color: var(--kanto-text-muted);
        margin-bottom: 8px;
      }
    }
    @media (min-width: 1201px) {
      .scroll-hint { display: none; }
    }

    /* Mobile refinements */
    @media (max-width: 768px) {
      .container { padding: 24px 16px 40px; }
      .header { margin-bottom: 24px; }
      .header-left h1 { font-size: 20px; }
      .header-left p { font-size: 12px; }
      .warning { font-size: 11px; padding: 8px 12px; }
      .observations { padding: 16px 18px; }
      .observations li { font-size: 11px; line-height: 1.8; }
      .site-footer { flex-direction: column; align-items: flex-start; gap: 8px; }
      .site-footer .left, .site-footer .right { font-size: 11px; }
    }

    /* Sortable headers */
    .sortable {
      cursor: pointer;
      user-select: none;
      transition: color 0.12s;
    }
    .sortable:hover {
      color: var(--kanto-text) !important;
    }
    .sort-arrow {
      font-size: 9px;
      opacity: 0.6;
      transition: opacity 0.12s;
    }
    .sortable.active .sort-arrow {
      opacity: 1;
    }

    @media (max-width: 480px) {
      .container { padding: 16px 12px 32px; }
      .header-left h1 { font-size: 18px; }
      .header-right a { padding: 5px 10px; font-size: 11px; }
      .observations h3 { font-size: 10px; }
    }
  </style>
</head>
<body>
  <div class="container">

    <!-- Header -->
    <div class="header">
      <div class="header-left">
        <h1>Taimi <span>— The AI Market Intelligence</span></h1>
CSSEOF

echo "        <p>Agentic coding tool pricing landscape · Free JSON API · ${updated_month} · ${tool_count} vendors compared</p>"

cat << 'BANNEREOF'
      </div>
      <div class="header-right">
        <span>Curated by</span>
        <a href="https://www.kantocompany.com/" target="_blank" rel="noopener">Kanto Company</a>
      </div>
    </div>

    <!-- Warning -->
    <div class="warning">
      ⚠ <strong>Usage-based units differ across vendors</strong> — not directly comparable.
      Tokens (per 1M), requests (per call), and ACUs (agent compute minutes) measure fundamentally different things.
      Click any price block to visit official pricing.
    </div>

    <div class="warning-platform">
      <strong>Platform plans<sup>P</sup>:</strong> Claude Code, OpenAI Codex, Mistral Vibe, and Google Antigravity subscription prices include their full platforms (Claude.ai, ChatGPT, Le Chat, Google AI) — not just the coding tool. API/usage plans are standalone.
    </div>

    <!-- Scroll hint for mobile -->
    <div class="scroll-hint">← scroll horizontally →</div>

    <!-- Matrix -->
    <div class="matrix">
      <div class="matrix-grid">

        <!-- Column headers (sortable) -->
        <div class="col-header h-vendor sortable" data-sort="name">Vendor <span class="sort-arrow">⇅</span></div>
        <div class="col-header h-free">Free Tier</div>
        <div class="col-header h-individual sortable" data-sort="individual">Individual <span class="sort-arrow">⇅</span></div>
        <div class="col-header h-team sortable" data-sort="team">Team / Seat <span class="sort-arrow">⇅</span></div>
        <div class="col-header h-usage">Usage-Based (PAYG)</div>
        <div class="col-header h-enterprise">Enterprise</div>

BANNEREOF

# ==================== TOOL ROWS (dynamic) ====================
generate_rows

# ==================== TAIL (observations, footer, script) ====================
cat << 'GRIDEOF'
      </div><!-- /matrix-grid -->
    </div><!-- /matrix -->

GRIDEOF

# Observations are editorial content — market-update agent edits data/observations.html
cat "$OBSERVATIONS"
echo ""

cat << 'FOOTEREOF'

    <!-- Footer -->
    <div class="site-footer">
      <div class="left">
        Curated by <a href="https://www.kantocompany.com/" target="_blank" rel="noopener">Kanto Company</a> — Green Lean technology consultancy · Helsinki & Tampere
      </div>
      <div class="right">
FOOTEREOF

echo "        Last updated: ${updated_display} · Data sourced from official vendor pricing pages · <a href=\"/v1/tools.json\">JSON API</a>"

cat << 'SCRIPTEOF'
      </div>
    </div>

  </div><!-- /container -->

  <script>
  (function() {
    const grid = document.querySelector('.matrix-grid');
    const headers = grid.querySelectorAll('.sortable');
    let currentSort = null;
    let ascending = true;

    headers.forEach(function(header) {
      header.addEventListener('click', function() {
        const key = this.dataset.sort;
        if (currentSort === key) {
          ascending = !ascending;
        } else {
          currentSort = key;
          ascending = true;
        }

        headers.forEach(function(h) {
          h.classList.remove('active');
          h.querySelector('.sort-arrow').textContent = '⇅';
        });
        this.classList.add('active');
        this.querySelector('.sort-arrow').textContent = ascending ? ' ▲' : ' ▼';

        var rows = Array.from(grid.querySelectorAll('.row'));
        rows.sort(function(a, b) {
          if (key === 'name') {
            var va = a.dataset.name;
            var vb = b.dataset.name;
            return ascending ? va.localeCompare(vb) : vb.localeCompare(va);
          }
          if (key === 'enterprise') {
            var va = parseFloat(a.dataset[key]);
            var vb = parseFloat(b.dataset[key]);
            return ascending ? vb - va : va - vb;
          }
          var va = parseFloat(a.dataset[key]);
          var vb = parseFloat(b.dataset[key]);
          if (va === 9999 && vb === 9999) return 0;
          if (va === 9999) return 1;
          if (vb === 9999) return -1;
          return ascending ? va - vb : vb - va;
        });
        rows.forEach(function(row) { grid.appendChild(row); });
      });
    });
  })();
  </script>
</body>
</html>
SCRIPTEOF
} > "$OUTPUT"

echo "Generated: $OUTPUT"
