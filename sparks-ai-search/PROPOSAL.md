# SPARKS AI Search — Proposal

**Prepared for:** NARB internal review → FED Lead
**Prepared by:** Vertical Relevance
**Jira:** SB-6562 — research & identify options to enable prompt searching
**Status:** Draft for internal (NARB) review before presenting to FED
**Scope:** Add an AI-assisted "Ask SPARKS" search experience **without changing** the existing OpenSearch search.
**Cost posture:** This is **research & proposal only — $0 AWS cost now.** No Bedrock/vector/Lambda is provisioned; spend begins **only after FED Lead approval**, starting with a capped Dev pilot. (See `COST_EFFORT_RESOURCES.md`.)

**Acceptance criteria (from SB-6562) → where satisfied:**

| Criterion | Artifact |
|---|---|
| ER Diagram for SPARKS | `diagrams/sparks-er-current-asis.drawio` (as-is, for reference) **and** `diagrams/sparks-er-option1-2-proposed.drawio` (proposed data model for Option 1 & 2 — the one to review) |
| Research Content Documentation | `HLD.md`, `LLD.md`, `diagrams/*` |
| Proposal Documents | this `PROPOSAL.md` + `SPARKS_AI_Search_Proposal.docx` / `.html` |
| NO COST in AWS | `COST_EFFORT_RESOURCES.md` §0 (NO-COST-NOW) |

---

## Table of contents
1. [Executive summary](#1-executive-summary)
2. [Current state (As-Is)](#2-current-state-as-is)
3. [The opportunity & guiding principles](#3-the-opportunity--guiding-principles)
4. [Option 1 — Generative AI / RAG Search](#4-option-1--generative-ai--rag-search)
5. [Option 2 — Agentic Hybrid Search](#5-option-2--agentic-hybrid-search)
6. [Options compared (and what we deferred)](#6-options-compared-and-what-we-deferred)
7. [High-Level Design (HLD)](#7-high-level-design-hld)
8. [Low-Level Design (LLD)](#8-low-level-design-lld)
9. [Recommendation & phased roadmap](#9-recommendation--phased-roadmap)
10. [Open questions for FED](#10-open-questions-for-fed)
11. [Appendix — diagrams & source grounding](#11-appendix--diagrams--source-grounding)

---

## 1. Executive summary

SPARKS today has a strong **structured search** (keyword + pills/filters) backed by Amazon OpenSearch. It answers "find records that match these fields" very well, but it cannot answer natural-language questions, summarize across records, find semantically similar cases, or support follow-up questions.

We propose adding a single **"Ask SPARKS" chat box** to the existing search experience. It is **one user experience with two retrieval capabilities behind it** — not a second search bar:

- **Exact / filtered lookups** keep using today's OpenSearch (unchanged).
- **Natural-language / semantic questions** use a new AI path.

The design is deliberately kept **simple and cost-bounded** — the current search is simple and reliable, and we are *extending* it with AI, not rebuilding it.

We present two AI options, both delivered as the same chat box:

| Option | What it is | Best for |
|---|---|---|
| **Option 1 — Generative AI (RAG)** | Retrieve from a curated copy of SPARKS data; **Claude** generates a grounded answer with citations | Q&A, summaries, "find similar cases," follow-ups |
| **Option 2 — Agentic AI** | An **agent** decides which approved tools to call (existing OpenSearch, vector search, record lookups), reasons across steps, then answers | Complex, multi-step questions |

**Key design decision:** the AI path reads the **same denormalized documents** SPARKS already produces for OpenSearch (the `sparks.open_search_json` outbox), **read-only**. Nothing in the current indexing pipeline changes. This directly answers "why two searches?" — there is one search experience; the AI simply reads an approved copy of the same data.

**Recommendation:** start with **Option 1 (RAG)** as the near-term, governable capability, architected so **Option 2 (Agentic)** is an additive evolution that reuses the same search content and the existing OpenSearch as a tool. See §9.

> **Delivery status:** Both options are specified **end-to-end and production-ready** — SPARKS owns the full stack (no external dependency). Locked architecture decisions, API spec, security/IAM, observability/SLOs, CI/CD, rollback, and a go-live runbook are in `PRODUCTION_DESIGN.md`; deployable **Terraform** is in `infra/terraform/` (one toggle switches Option 1 ↔ Option 2). Nothing is provisioned until FED approval.

> **EDMAS note:** EDMAS (a sister NHTSA/DOT project) already runs a GenAI/RAG search on Bedrock. Per the latest EDMAS–SPARKS exchange, EDMAS is **not** expected to host any Vector DB / AI capability for SPARKS, and neither team works directly on the other's tasks — so this proposal is scoped for **SPARKS to own its own AI stack**, which matches that note. An upcoming EDMAS meeting *may* let us reuse some EDMAS AI components; if so, that would **reduce** our build footprint. We treat EDMAS as a knowledge-exchange checkpoint, **not a dependency**.

---

## 2. Current state (As-Is)

> **Diagram:** `diagrams/current-sparks-search.drawio`

SPARKS keeps OpenSearch populated with a scheduled, outbox-based indexing pipeline, and the UI searches that index.

**Indexing pipeline (every 5 minutes):**
1. **Amazon EventBridge** triggers the **RDS-to-SQS Lambda**.
2. In **Amazon RDS (PostgreSQL)**, domain builders (`json_vtf_rec()`, `json_etf_rec()`, `json_etfi_rec()`, `json_gi_rec()`, `json_vtfi_rec()`, and legacy `json_legacy_vehicle_rec()` / `json_legacy_equipment_rec()` / `json_legacy_investigation_rec()`) produce **denormalized document arrays**. `pushIndexToOpenSearchTable()` calls `pushJsonData(json, index)` to write them to the **`sparks.open_search_json`** outbox table.
3. The **RDS-to-SQS Lambda** selects unread rows (`osj_read_yn = false`, `LIMIT 50`), sends them to **Amazon SQS `SearchQueue.fifo`** in batches of 10 (message carries **IDs only** — `osj_id` + index name, not the payload), and marks rows `osj_read_yn = true`.
4. The **SQS-to-OpenSearch Lambda** re-fetches the payload by `osj_id`, ensures the index exists (never deletes), chunks at 1000 docs, stamps a stable `_id` via `_stableId()` (legacy → `legacy_equipment:<id>` etc.; non-legacy → `uniqueId ?? id`), bulk-indexes to **Amazon OpenSearch (sparks-stage)**, and marks `osj_processed_yn = true`.

**User search path:** SPARKS UI (pills/filters/keyword) → Search API → OpenSearch → results.

**Two facts from the real data that shape the whole proposal:**
- The outbox documents are **already AI-ready** — flat business documents with rich free text (`failure_desc`, `prob_summary`) plus structured facets (`fmvss_code`, `brand`, `test_results`, dates).
- Every document carries a **`uniqueId`** (e.g. `legacy_equipment:12251`) that the consumer turns into the OpenSearch `_id`. This is a ready-made **citation key** that lets AI answers link 1:1 to real records.

---

## 3. The opportunity & guiding principles

**What's missing today:** natural-language questions, semantic similarity, summarization, cross-record reasoning, follow-ups, grounded answers with sources.

**Guiding principles for the design:**
1. **Don't disrupt production search.** The existing OpenSearch pipeline is untouched.
2. **One experience, not two searches.** Add a chat box to the same UI; route exact vs. semantic behind the scenes.
3. **Reuse what exists.** Read the same outbox documents; reuse `uniqueId` as the citation key.
4. **Keep it simple & cost-safe.** Extend the existing simple search; cap scope and spend; nothing applies until FED approval.
5. **Governable & grounded.** Read-only data access, least-privilege, Bedrock guardrails, every answer cites sources.
6. **Evolvable.** Build RAG first; make Agentic an additive step, not a rebuild.

---

## 4. Option 1 — Generative AI / RAG Search

> **Diagram:** `diagrams/option1-rag.drawio`

**Flow:** User asks a question in the **Ask SPARKS** chat box → **API Gateway** → **Orchestrator Lambda** → intent router (exact → existing OpenSearch; semantic → RAG) → **Amazon Bedrock Knowledge Base** embeds the query and retrieves from the **vector index** → **Claude on Bedrock** generates a grounded answer with **citations (reusing `uniqueId`)** → answer card in the UI.

**AI data preparation (new, read-only):** a scheduled **Lambda/Glue** job reads `osj_json_data` from the outbox read-only, optionally **enriches** it (populate `failure_type` / `prob_summary` / `sme_recc`, add related comments, status history, reference values), and writes **curated search content to Amazon S3**, partitioned by domain, one object per `uniqueId`. Bedrock Knowledge Base ingests S3 → chunks + embeds → vector index.

**Why this is the strong near-term choice:**
- Reuses existing documents and citation keys; **no change to the indexing pipeline**.
- Managed, governable retrieval; grounded answers with sources.
- "Enrich the search content" is low-cost because it only augments a **copy** — operational tables are never touched.

**Answers "why two searches?":** one chat box; the AI reads an approved copy of the same data; exact/filter still uses the current OpenSearch.

---

## 5. Option 2 — Agentic Hybrid Search

> **Diagram:** `diagrams/option2-agentic.drawio`

Everything in Option 1, **plus an agent** that decides *how* to answer. The **same chat box** now sits in front of an **Amazon Bedrock Agent (Claude)** that plans multi-step queries and calls an **approved tool set**:

- `openSearchSearch(query, filters)` → the **existing** OpenSearch index (exact/filter)
- `semanticSearch(query, filters, top_k)` → the Option 1 vector index
- `getInvestigation()` / `getVehicle()` / `getEquipment()` → **read-only** record lookups by `uniqueId`
- (optional) approved reference docs / procedures / APIs — **no raw SQL tool**

The agent combines results (deduping by `uniqueId`), applies **Bedrock Guardrails**, and returns a grounded, multi-source answer.

**Best for:** "Find Ford investigations since 2022 involving camera/visibility failures, compare them, and tell me which resulted in recalls" — questions that need several steps and sources.

**Key point:** the existing OpenSearch is reused **as one of the agent's tools** — Option 2 is an evolution of Option 1, not a different system.

---

## 6. Options compared (and what we deferred)

| Dimension | Option 1 — RAG | Option 2 — Agentic |
|---|---|---|
| User interface | "Ask SPARKS" chat box | Same chat box |
| Core behavior | Retrieve → generate | Plan → call tools → generate |
| Reuses existing OpenSearch | As the exact/filter path | As an agent **tool** |
| Complexity / risk | Lower | Higher (multi-step orchestration) |
| Governance | Straightforward (fixed retrieval) | Needs tool allow-listing + guardrails |
| Best at | Q&A, summaries, similar cases | Multi-step, cross-record reasoning |
| Time-to-value | Near-term | Evolution of Option 1 |

**Deliberately deferred** (noted so FED sees we considered them):

| Pattern | Why deferred |
|---|---|
| Text-to-SQL agent | Injection / governance risk on production PostgreSQL |
| Fine-tuned domain model | Cost, data handling, retraining burden |
| GraphRAG / knowledge graph | High build cost; revisit for cross-failure pattern mining |

---

## 7. High-Level Design (HLD)

The full HLD is maintained in **`HLD.md`**. Summary:

- **Purpose:** add NL/semantic "Ask SPARKS" without replacing structured search.
- **Baseline:** unchanged EventBridge → RDS-to-SQS → FIFO → SQS-to-OpenSearch → OpenSearch pipeline; outbox documents carry `uniqueId`.
- **Option 1 target:** `PostgreSQL (unchanged) → [new, read-only] AI extractor → (enrich) → S3 curated search content → Bedrock KB → vector index → Claude → Ask SPARKS`, with exact/filter still served by existing OpenSearch.
- **Option 2 target:** add a Bedrock Agent with approved tools (existing OpenSearch, vector search, read-only lookups); no unrestricted SQL.
- **Data domains:** the 5 core + 3 legacy indexes; search content starts as 1:1 reuse and expands per domain.
- **Non-functional:** read-only access + least-privilege; guardrails; citations; search-content refresh cadence; cost (embeddings/inference/vector sizing); evaluation before go-live.

---

## 8. Low-Level Design (LLD)

The full LLD is maintained in **`LLD.md`**. Summary:

- **Search-content document schema:** confirmed from a real `legacy_equipment` payload. Roles: `uniqueId` = citation key; `failure_desc` / `prob_summary` / `sme_recc` / `product_desc` / `test_results` = primary embedding text; `fmvss_code` / `compliance_prg_yr` / `brand` / `manufacturer` / `vehicle_make` / `lab_name` / `test_results` = filters/facets; `report_accept_dt` / `create_dt` / `update_dt` = dates.
- **AI extractor:** scheduled; read-only `SELECT` from `sparks.open_search_json`; normalize string-or-array payload (mirroring the consumer); optional enrichment; write `s3://sparks-ai-search-content/<domain>/<uniqueId>.json`.
- **Chunking/embedding:** chunk long `failure_desc`; keep structured fields as metadata; store `uniqueId`/domain/facets as chunk metadata for filtered retrieval.
- **Vector store options:** OpenSearch vector index (recommended — same domain already run), pgvector, or S3 Vectors.
- **Retrieval/generation contract:** request `{query, filters, top_k}` → response `{answer, citations[] (with uniqueId), followups[]}`; **every claim cites ≥1 `uniqueId`**.
- **Evaluation:** golden Q&A set with known-correct citations; metrics (recall@k, citation correctness, groundedness, relevance); deterministic + LLM-judge + SME spot check; acceptance thresholds before go-live.
- **Option 2 tool contracts:** `openSearchSearch`, `semanticSearch`, `getInvestigation/getVehicle/getEquipment` — all read-only; agent merges by `uniqueId`; **no raw SQL tool**.
- **Explicitly unchanged:** both Lambdas, `SearchQueue.fifo`, `pushJsonData`, `pushIndexToOpenSearchTable`, all `json_*_rec()` builders, the outbox schema/flags, existing indexes, and the current pills/filters/keyword UI.

---

## 9. Recommendation & phased roadmap

**Recommendation:** Build **Option 1 (RAG)** first as the governable near-term capability, architected so **Option 2 (Agentic)** is an additive layer that reuses the same search content and the existing OpenSearch as a tool.

| Phase | Deliverable | Outcome |
|---|---|---|
| **0 — Foundations** | Confirm open questions (§10); provision S3 search-content bucket, Bedrock KB, vector index; IAM least-privilege; read-only outbox access | Guardrails and plumbing in place |
| **1 — RAG MVP (Option 1)** | Extractor (reuse-only, no enrichment) → S3 → KB → Claude; "Ask SPARKS" chat box wired into existing UI; citations via `uniqueId` | Natural-language Q&A over current data |
| **2 — Enrich & evaluate** | Enrich search content (`failure_type`/`prob_summary`/`sme_recc`, comments, status history); golden Q&A set + acceptance thresholds | Broader coverage; measured quality |
| **3 — Agentic (Option 2)** | Add Bedrock Agent + approved tools (existing OpenSearch, semantic search, read-only lookups); guardrails | Multi-step, cross-record reasoning |

---

## 10. Open questions for FED

1. **Vector store:** OpenSearch vector index (recommended) vs pgvector vs S3 Vectors?
2. **Retrieval:** Bedrock Knowledge Base (managed) vs a custom retrieval pipeline?
3. **Enrichment scope for v1:** reuse-only, or enrich `failure_type` / `prob_summary` / `sme_recc` from the start?
4. **FE integration contract:** how does "Ask SPARKS" slot into the current search UI (same page/panel, response rendering, citation click-through)?
5. **Search-content freshness:** align the AI search-content refresh to the 5-minute cycle, or a slower batch?
6. **Current search internals:** does the UI query OpenSearch via API Gateway + Lambda (as drawn), or another path? (Confirm so the As-Is diagram is exact.)
7. **EDMAS reuse:** following the upcoming EDMAS meeting, are any EDMAS AI components (already running GenAI/RAG) available for SPARKS to reuse — which would reduce our build?

---

## 11. Appendix — diagrams & source grounding

**draw.io diagrams** (open in [app.diagrams.net](https://app.diagrams.net) → File → Open; every box is labeled with its AWS service + role):
- `diagrams/sparks-er-current-asis.drawio` — **ER diagram, As-Is** (existing data model, for reference)
- `diagrams/sparks-er-option1-2-proposed.drawio` — **ER diagram, Proposed (Option 1 & 2)** — new AI data entities keyed on `uniqueId` (**the one for proposal review**)
- `diagrams/current-sparks-search.drawio` — Current state (As-Is)
- `diagrams/option1-rag.drawio` — Option 1 (Generative AI / RAG)
- `diagrams/option2-agentic.drawio` — Option 2 (Agentic Hybrid)

**Cost / effort / resources:** `COST_EFFORT_RESOURCES.md` — the "sell-wise" breakdown for NARB (resources, LLM, vectorization/pgvector decision, token & cost model, effort/complexity, phasing, risks). All figures are estimates; **$0 is spent under this story**.

**Mermaid diagrams** (render on GitHub; same content, lighter weight):
- `diagrams/01-current-state.md`, `diagrams/02-future-option1-rag.md`, `diagrams/03-future-option2-agentic.md`

**Design docs:** `HLD.md`, `LLD.md`, **`PRODUCTION_DESIGN.md`** (E2E prod-ready: locked decisions, API spec, security/IAM, observability/SLOs, CI/CD, rollback, go-live runbook)

**Infrastructure as Code:** `infra/terraform/` — modular, well-commented Terraform (Dev env + 6 modules: `ai_search_content`, `vector_index`, `bedrock_rag`, `ask_api`, `agent`, `observability`). `enable_agent=false` → Option 1 only; `true` → adds Option 2. **No `apply` until FED approval** (`validate`/`plan` are free).

**Source grounding:** this proposal is based on the actual SPARKS code — the RDS-to-SQS Lambda, the SQS-to-OpenSearch Lambda, the `sparks.pushjsondata` and `sparks.pushindextoopensearchtable` PL/pgSQL functions, and a real `osj_json_data` (`legacy_equipment`) payload. Where a detail was not evident from the code (e.g. the exact FE→OpenSearch query path), it is flagged as an open question (§10).
