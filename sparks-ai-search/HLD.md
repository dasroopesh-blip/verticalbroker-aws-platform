# SPARKS AI Search — High-Level Design (HLD)

> Proposal artifact. Grounded in the current SPARKS indexing code
> (`RDS-to-SQS` Lambda, `SQS-to-OpenSearch` Lambda, `sparks.pushjsondata`,
> `sparks.pushindextoopensearchtable`) and a real `osj_json_data` sample.

## 1. Purpose
Add a natural-language / semantic "Ask SPARKS" capability **without replacing or
modifying** the existing OpenSearch keyword/filter search. Two options are proposed:

- **Option 1 — RAG / Generative AI Search:** retrieve from a curated (optionally
  enriched) copy of SPARKS data; Claude produces grounded answers with citations.
- **Option 2 — Agentic Hybrid Search:** an agent orchestrates approved tools
  (existing OpenSearch, vector/semantic search, read-only lookups) for multi-step questions.

The other agentic patterns (text-to-SQL agent, fine-tuned domain model, GraphRAG) are
**deliberately deferred** for governance/cost/complexity reasons and noted in §7.

## 2. Current state (baseline — unchanged)
EventBridge (5 min) → RDS-to-SQS Lambda → `SearchQueue.fifo` → SQS-to-OpenSearch Lambda → OpenSearch.
The DB builders write denormalized document arrays into the `sparks.open_search_json`
outbox via `pushJsonData`; the FIFO message carries only `osj_id` + index name; the
consumer re-fetches the payload, stamps a stable `_id` from each doc's `uniqueId`, and
bulk-indexes. See `diagrams/01-current-state.md`.

**Key reuse point:** the outbox already contains AI-ready documents with citation keys
(`uniqueId`, e.g. `legacy_equipment:12251`). The AI path reads this outbox **read-only**.

## 3. Target architecture — Option 1 (RAG)
```
SPARKS PostgreSQL (unchanged)
  -> [existing] builders -> open_search_json -> RDS-to-SQS -> FIFO -> SQS-to-OpenSearch -> OpenSearch -> keyword/filter search
  -> [new, read-only] AI extractor -> (enrich) -> S3 curated search content -> Bedrock KB (chunk/embed) -> vector store -> Claude -> Ask SPARKS
```
- **AI data prep:** scheduled Lambda/Glue reads `osj_json_data` read-only; optionally
  enriches (populate `failure_type`/`prob_summary`/`sme_recc`, add related comments,
  status history, reference values). Writes curated JSON to S3, partitioned by domain.
- **Retrieval:** Bedrock Knowledge Base chunks + embeds; vectors stored in an
  **OpenSearch vector index** (lowest friction for a shop already running OpenSearch;
  pgvector / S3 Vectors are alternatives — see LLD §4).
- **Generation:** Claude returns a grounded answer, summaries, and **citations that
  reuse `uniqueId`**, so each cited source maps 1:1 to an OpenSearch `_id`.
- **UX:** one search surface. Exact/filtered → existing OpenSearch. NL/semantic → RAG.

See `diagrams/02-future-option1-rag.md`.

## 4. Target architecture — Option 2 (Agentic)
Adds a Bedrock Agent whose approved tools include `openSearchSearch()` (the **existing**
index), `semanticSearch()` (the Option 1 vector index), and read-only
`getInvestigation()/getVehicle()/getEquipment()` lookups by `uniqueId`. The agent plans
multi-step queries, combines results, and grounds the response. No unrestricted SQL.
See `diagrams/03-future-option2-agentic.md`.

## 5. Data domains (from the real builders)
`vehicle_test_file`, `equip_test_file`, `equip_test_failure_inv`, `general_inv`,
`vehicle_test_failure_inv`, and legacy `legacy_vehicle` / `legacy_equipment` /
`legacy_investigation`. The AI search content can start as a 1:1 reuse of these and expand
per domain without new operational tables.

## 6. Non-functional (to confirm with FED)
- **Security/governance:** read-only access to the outbox; curated search content in S3 with
  least-privilege; Bedrock guardrails; citations for traceability.
- **Freshness:** AI search content refresh cadence (align to the 5-min cycle or a slower batch).
- **Cost:** embedding + inference volume; vector store sizing.
- **Evaluation:** golden Q&A set + acceptance thresholds before go-live (LLD §6).

## 7. Deliberately deferred options
| Pattern | Why deferred |
|---|---|
| Text-to-SQL agent | Injection/governance risk on prod PostgreSQL |
| Fine-tuned domain model | Cost, data handling, retraining burden |
| GraphRAG / knowledge graph | High build cost; revisit for cross-failure pattern mining |

## 8. Open questions
- Vector store choice (OpenSearch vector index vs pgvector vs S3 Vectors)?
- Bedrock Knowledge Base (managed) vs custom retrieval pipeline?
- Enrichment scope for v1 (reuse-only vs enrich `failure_type`/`prob_summary`/`sme_recc`)?
- FE integration contract for "Ask SPARKS" within the existing search UI?
