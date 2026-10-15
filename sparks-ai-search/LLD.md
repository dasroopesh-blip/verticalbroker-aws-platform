# SPARKS AI Search — Low-Level Design (LLD)

> Companion to `HLD.md`. Concrete contracts grounded in the real code and the
> observed `osj_json_data` document shape.

## 1. Search-content document schema (from real `legacy_equipment` payload)
Each outbox row's `osj_json_data` is an **array** of flat documents. Example (legacy_equipment):

```json
{
  "searchModule": "legacyEquipment",
  "uniqueId": "legacy_equipment:12251",
  "equipment_id": 12251,
  "legacy_report_no": "213-NAW-07-011",
  "legacy_report_hs_no": 648221,
  "file_no": "213-0717896-TEST",
  "certifying_party": "",
  "manufacturer": "Evenflo Company Inc.",
  "brand": "Evenflo",
  "model": "395 Triumph 5 Premier",
  "vehicle_make": "", "vehicle_model": "", "vehicle_model_yr": null,
  "fmvss_code": "213",
  "compliance_prg_name": "Equipment Compliance Program 2007",
  "compliance_prg_yr": 2007,
  "lab_name": "MGA",
  "assigned_to_name": "Zachary Fraser",
  "test_results": "Fail",
  "product_desc": "Child Seat",
  "model_number": "393",
  "mfr_dot_code": "", "importer": "", "owner_packager": "",
  "failure_type": "Labeling",
  "failure_desc": "The child seat was found to be noncompliant with S5.5.1 and S5.5.2(g)(iv)...",
  "prob_summary": null,
  "sme_recc": null,
  "update_dt": "2026-05-08", "create_dt": "2026-05-08",
  "report_accept_dt": "2007-09-17"
}
```

### Field roles for retrieval
| Role | Fields |
|---|---|
| **Citation key** | `uniqueId` (maps to OpenSearch `_id` via `_stableId`) |
| **Primary embedding text** | `failure_desc`, `prob_summary`, `sme_recc`, `product_desc`, `test_results` |
| **Structured filters / facets** | `fmvss_code`, `compliance_prg_yr`, `brand`, `manufacturer`, `vehicle_make`, `lab_name`, `assigned_to_name`, `test_results` |
| **Dates** | `report_accept_dt`, `create_dt`, `update_dt` |

> Other domains (`general_inv`, `*_test_file`, `*_failure_inv`) follow the same flat,
> `uniqueId`-keyed shape produced by their `json_*_rec()` builders — confirm exact fields per domain.

## 2. AI data preparation (read-only extractor)
- **Trigger:** scheduled (EventBridge). Cadence TBD (align to 5-min cycle or slower batch).
- **Read:** `SELECT osj_id, osj_table_index_name, osj_json_data FROM sparks.open_search_json`
  (read-only; **no writes to the outbox**, no change to `osj_read_yn`/`osj_processed_yn`).
- **Normalize:** `osj_json_data` may be a JSON string or array (mirror the consumer's
  `Array.isArray(...) ? ... : JSON.parse(...)` handling).
- **Enrich (optional, v1 can skip):** populate null `failure_type`/`prob_summary`/`sme_recc`,
  attach related comments / status history / reference-table lookups.
- **Write:** one object per document to S3, e.g.
  `s3://sparks-ai-search-content/<domain>/<uniqueId>.json`, preserving `uniqueId`.

## 3. Chunking & embedding (Bedrock Knowledge Base)
- Chunk long `failure_desc` fields; keep structured fields as metadata (not embedded as prose).
- Store `uniqueId`, `domain`, and key facets as chunk metadata for filtered retrieval.
- Embedding model: Bedrock Titan / Cohere (confirm with FED standards).

## 4. Vector store options
| Option | Pros | Cons |
|---|---|---|
| **OpenSearch vector index** (recommended) | Same domain already running; one system to govern; k-NN + filters | Shares cluster capacity |
| pgvector | Co-located with source; SQL-native | Adds load to RDS; new extension |
| S3 Vectors | Cheap at rest; serverless | Newer; fewer filter features |

## 5. Retrieval + generation contract
**Request (from Ask SPARKS):**
```json
{ "query": "child seats that failed labeling under FMVSS 213 since 2020",
  "filters": { "fmvss_code": "213", "compliance_prg_yr_gte": 2020 },
  "top_k": 8 }
```
**Response (Claude, grounded):**
```json
{
  "answer": "…natural-language summary…",
  "citations": [
    { "uniqueId": "legacy_equipment:12251", "brand": "Evenflo",
      "test_results": "Fail", "failure_type": "Labeling",
      "snippet": "noncompliant with S5.5.1 and S5.5.2(g)(iv)…" }
  ],
  "followups": ["Compare to 2008 program results", "Show similar Graco cases"]
}
```
- **Citation rule:** every claim links to ≥1 `uniqueId`; the UI resolves it to the
  existing record (same `_id` as OpenSearch). No un-cited assertions.

## 6. Evaluation (before go-live)
- **Golden set:** curated Q&A pairs with known-correct `uniqueId` citations.
- **Metrics:** retrieval recall@k, citation correctness, groundedness/no-hallucination,
  answer relevance. Deterministic checks + LLM-judge, with SME spot review.
- **Acceptance thresholds:** agree with FED (e.g. recall@8 ≥ target, 0 un-cited claims).

## 7. Option 2 — agent tool contracts (additive)
```
openSearchSearch(query, filters)      -> hits[] (EXISTING index; _id == uniqueId)
semanticSearch(query, filters, top_k) -> chunks[] with uniqueId metadata
getInvestigation(uniqueId)            -> doc (read-only)
getVehicle(uniqueId) / getEquipment(uniqueId) -> doc (read-only)
```
- Agent plans tool calls, merges results by `uniqueId` (dedupe), grounds the answer.
- **No raw SQL tool.** All data access is through approved, read-only tools.

## 8. What stays untouched (explicit)
- `RDS-to-SQS` Lambda, `SQS-to-OpenSearch` Lambda, `SearchQueue.fifo`.
- `sparks.pushjsondata`, `sparks.pushindextoopensearchtable`, all `json_*_rec()` builders.
- `sparks.open_search_json` schema and its `osj_read_yn`/`osj_processed_yn` flags.
- Existing OpenSearch indexes and the current pills/filters/keyword UI.
