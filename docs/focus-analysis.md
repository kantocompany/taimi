# FOCUS Specification Analysis

Researched 2026-03-11. Evaluates whether Taimi should align with the FinOps Foundation's FOCUS (FinOps Open Cost and Usage Specification).

## What FOCUS is

FOCUS (v1.3, ratified Dec 2025) is an open billing data interchange format — 77 columns normalizing actual incurred charges across cloud/SaaS providers. Adopted by AWS, Azure, GCP, Oracle, and others for native billing exports.

It answers **"what did I spend and why?"** via line-item charge rows with discount waterfalls (list → contracted → effective → billed), virtual currency support, commitment tracking, and resource-level cost allocation.

Spec: https://focus.finops.org/

## How Taimi differs

Taimi is a **pricing catalog** — it answers **"what would I spend if I chose this tool?"**

| | FOCUS | Taimi |
|---|---|---|
| Data type | Billing line items (retrospective) | Plan definitions (prospective) |
| Granularity | Individual charge rows per resource/hour | Plan structures per vendor |
| Schema size | 77 columns | ~15 fields per plan |
| Concepts modeled | Charges, discounts, resources, billing periods | Plans, tiers, capabilities, benchmarks |
| Not modeled | Plans, included limits, features, benchmarks | Charge rows, discount waterfalls, allocation |

These are adjacent but non-overlapping. FOCUS has no concept of "plans," "tiers," "included limits," or "capabilities." Taimi has no concept of charge rows, billing periods, or resource-level allocation.

## Verdict

**Taimi's schema is correct for its purpose.** No changes needed to align with FOCUS.

The plan category enum (`free`, `individual`, `team`, `enterprise`, `usage`) maps to how procurement evaluates. Platform bundling (`platform_plan`) solves a comparison problem FOCUS doesn't address. Overage unit typing (`token`, `request`, `acu`) is honest about incomparability rather than pretending to normalize.

## Ideas worth borrowing (not now)

**Unit descriptions.** FOCUS v1.2 solved "tokens vs credits vs DBUs" with explicit unit semantics. Taimi's overage `notes` field serves this role loosely. A structured `unit_description` field could help MCP server consumers in v2.1, but free-text notes work fine today.

**FOCUS export bridge.** If enterprises adopt Taimi data into FinOps workflows, mapping Taimi plan IDs to FOCUS `ServiceName`/`SkuId` would enable consolidated pre+post-purchase cost views. A v3 concern at earliest.

## Position in the ecosystem

```
Taimi (before purchase)  →  Decision  →  FOCUS (after purchase)
"What will it cost?"                     "What did it cost?"
```

LLM token pricing is served by LiteLLM/OpenRouter. Cloud billing normalization is served by FOCUS. Tool-level pricing catalogs for agentic coding tools — that's the gap Taimi fills.
