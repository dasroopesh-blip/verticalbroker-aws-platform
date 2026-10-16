# SPARKS AI Search — Proposal

**SB-6562 — Research and identify options to enable prompt-based search**
Refined design for NARB internal review → FED Lead

> **Scope:** Research and proposal only. Add AI-assisted search capabilities **without changing** the existing OpenSearch indexing pipeline or operational PostgreSQL schema.

> **Cost posture:** No AWS resources are provisioned under this analysis. Any Dev implementation, model usage, vector storage, or other spend begins **only after approval** and cost controls are agreed.

---

## 1. Executive Summary

SPARKS already has a reliable structured search capability backed by Amazon OpenSearch. The current solution is optimized for keyword search, pills/filters, identifiers, and other structured lookups. The opportunity is to add natural-language search, semantic retrieval, summaries, similar-case discovery, follow-up questions, and grounded answers with links back to SPARKS records.

This proposal narrows the AI choices to two practical architectures:

- **Option 1 — Generative AI / RAG Search:** a separate retrieval-augmented generation path over a curated and optionally enriched copy of approved SPARKS data.
- **Option 2 — Agentic Hybrid Search:** an orchestration layer that can choose among approved search tools, including the existing OpenSearch search, semantic/vector retrieval, and read-only record lookups.

> **Recommendation:** Present both options to FED, with **Option 1** as the lower-complexity near-term path and **Option 2** as the advanced evolution for multi-step questions. Neither option requires changes to the current RDS→SQS→OpenSearch indexing pipeline.

### What was refined from the initial draft

| Refinement | Why it matters |
|---|---|
| Removed over-claims | The initial draft described the design as "production-ready," referenced deployable Terraform, and implied locked decisions. Those claims are not required for a research/proposal Jira and should be proven separately before FED review. |
| Corrected source-data assumptions | Existing search JSON is useful and often rich, but it is not automatically a complete AI search content set. The AI design now supports reuse, enrichment, or new AI-specific domain documents where current search JSON has gaps. |
| Separated RAG from Agentic behavior | Option 1 is fixed retrieval + generation. Tool selection, multi-step planning, and combining existing OpenSearch with vector retrieval belong in Option 2. |
| Corrected identifier language | The consumer can derive stable document IDs; not every source document should be assumed to already carry a universal `uniqueId`. The AI search content should preserve a stable source key that maps back to SPARKS. |
| Simplified FED decision points | The refined proposal focuses on business value, architecture boundaries, data strategy, governance, and decisions needed before any implementation. |

---

## 2. Current State — As-Is Search

The existing indexing flow is intentionally retained as the baseline. It uses PostgreSQL functions to create denormalized domain JSON, stages the payload in `sparks.open_search_json`, uses SQS as transport, and indexes the documents into Amazon OpenSearch.

### Exact sequence and state logic

1. An EventBridge schedule invokes the RDS-to-SQS Lambda on its configured cadence.
2. The Lambda calls `sparks.pushIndexToOpenSearchTable()`, which invokes the domain JSON builders and `pushJsonData()`.
3. `pushJsonData()` inserts or updates `sparks.open_search_json` and resets `osj_read_yn=false` and `osj_processed_yn=false` for new/changed content.
4. The RDS-to-SQS Lambda selects unread rows, sends SQS messages containing the `osj_id` and target index name, then marks successfully queued rows `osj_read_yn=true`.
5. The SQS-to-OpenSearch Lambda receives the message, reads `osj_json_data` back from PostgreSQL by `osj_id`, normalizes the payload, assigns stable document IDs, and bulk-indexes it into the target OpenSearch index.
6. After indexing, the consumer marks `osj_processed_yn=true`. `pushJsonData()` also contains retry logic for rows that are read but remain unprocessed beyond the configured threshold.

| State | Meaning |
|---|---|
| `read=false, processed=false` | New or changed JSON is staged and waiting to be queued. |
| `read=true, processed=false` | The row was handed to SQS and is awaiting / undergoing downstream indexing. |
| `read=true, processed=true` | The row completed the OpenSearch indexing path. |

### What the current search does well

- Exact identifiers and structured fields
- Keyword search
- Pills, filters, and facets
- Fast retrieval from a pre-built search index
- A proven asynchronous indexing pipeline decoupled from direct UI queries to PostgreSQL

### What the AI proposal adds

- Natural-language questions
- Semantic similarity and "find cases like this"
- Cross-record summaries and comparisons
- Grounded answers with source record links/citations
- Conversational follow-up questions
- For the agentic option, multi-step orchestration across approved tools

---

## 3. Design Principles

| Principle | Application to SPARKS |
|---|---|
| Do not disrupt current search | No changes are required to the current JSON builders, `open_search_json` flags, RDS-to-SQS Lambda, `SearchQueue.fifo`, SQS-to-OpenSearch Lambda, or current OpenSearch indexes for the proposal. |
| One SPARKS experience | The UI can expose current structured search and Ask SPARKS in the same search area/page. They are complementary capabilities, not competing products. |
| Read-only AI data access | The AI ingestion/data-preparation path reads approved data only. It does not write back to operational SPARKS data. |
| Curate before embedding | Do not blindly vectorize every PostgreSQL table. Build business-domain documents with useful context and preserve source keys for traceability. |
| Reuse where useful; enrich where needed | Current OpenSearch JSON is a strong starting point. Where it is incomplete for AI use cases, enrich the copy or create AI-specific JSON/domain documents. |
| Ground every answer | AI responses should point back to source records or approved documents and clearly distinguish retrieved facts from generated synthesis. |
| Cost only after approval | This Jira is research/design. No managed AI/vector resources should be created until FED approval and a cost ceiling are agreed. |

---

## 4. Option 1 — Generative AI / RAG Search

Option 1 adds a new AI retrieval path without modifying the existing OpenSearch indexing path. The goal is to let users ask questions in natural language and receive grounded answers, summaries, similar cases, citations, and follow-up questions.

### How it works

1. Use an approved read-only source from SPARKS. Start by reusing existing domain JSON where it contains the required data.
2. Normalize and curate the content for AI retrieval. Enrich the search content when current search JSON omits fields or relationships needed for the target questions.
3. Store/index the curated content in an approved AI retrieval layer. A Bedrock Knowledge Base or equivalent managed retrieval pattern can perform chunking/embedding and retrieve relevant context.
4. Claude generates an answer **only from retrieved SPARKS context** and returns source identifiers/links with the answer.
5. Existing pills/filters/keyword search remains available unchanged. Ask SPARKS is an additional AI-assisted interaction in the same application experience.

### Data strategy — avoid locking RAG to today's search coverage

| Data approach | When to use | Trade-off |
|---|---|---|
| Reuse current domain JSON | Fastest way to evaluate AI over data already prepared for search. | Coverage is limited to what current JSON builders already include. |
| Enrich the current JSON copy | Recommended when most current documents are useful but specific fields/relationships are missing. | Adds a controlled enrichment step, but does not modify operational tables. |
| Add AI-specific domain JSON | Use when AI questions require broader context than current search was designed to contain. | More design/data-engineering effort, but gives the cleanest long-term search content. |

### User value

- "Show investigations similar to this failure."
- "Summarize common failure patterns for FMVSS 111."
- "Find vehicle tests involving rear-camera response delays and explain the common findings."
- "What records support this answer?" — return source IDs/links instead of an ungrounded narrative.

### Strengths and limitations

| Strengths | Limitations / considerations |
|---|---|
| Lower complexity than an agent; fixed retrieval flow is easier to test and govern. | The model can only answer from content made available to the RAG search content. |
| Does not alter current OpenSearch ingestion or search behavior. | Search-content quality, chunking, metadata, and freshness directly affect retrieval quality. |
| Can expand beyond current search by enriching the AI search content. | If a question requires live tool calls or several dependent steps, RAG alone may be insufficient. |
| Good fit for summaries, semantic similarity, Q&A and follow-ups. | A citation/linking strategy must be defined for each domain document. |

---

## 5. Option 2 — Agentic Hybrid Search

Option 2 adds an orchestration layer that can decide how to answer a question using a controlled set of SPARKS tools. It is appropriate when a single question may require several retrieval steps, exact filters, semantic similarity, record lookups, or multiple approved sources.

### Approved tool model

| Tool | Purpose |
|---|---|
| OpenSearch search tool | Use the current OpenSearch index for exact identifiers, keyword search, filters, dates, facets, and other structured retrieval. |
| Semantic / vector search tool | Retrieve conceptually similar SPARKS records from the AI search content. |
| Record detail tools | Read-only APIs/functions for investigation, vehicle, equipment, test or related record details by stable source key. |
| Approved reference/document retrieval | Optional future access to policies, procedures, reference documents, or other governed sources. |

> **Guardrail:** Do not expose unrestricted SQL as an agent tool. The agent should interact through purpose-built, read-only contracts with explicit scopes and auditable inputs/outputs.

### Example multi-step question

*"Find Ford investigations since 2022 involving camera or visibility failures, compare the failures, and tell me which resulted in recalls."*

1. Parse manufacturer, date range, concept, comparison requirement, and recall outcome.
2. Use structured OpenSearch filters for manufacturer/date and semantic retrieval for camera/visibility concepts.
3. Retrieve details for the matching records.
4. Deduplicate/merge by stable source key.
5. Generate a comparison and cite the records that support each finding.

### Strengths and limitations

| Strengths | Limitations / considerations |
|---|---|
| Best fit for complex, multi-step questions. | Higher implementation and testing complexity than fixed RAG. |
| Reuses the existing OpenSearch as a tool instead of replacing it. | Requires strict tool allow-listing, IAM boundaries, logging, timeout/retry behavior, and guardrails. |
| Can combine exact search, semantic retrieval, and record lookups. | Agent plans can be non-deterministic; evaluation must cover tool choice and final-answer grounding. |
| Extensible to future approved data sources. | More model calls/tool calls can increase latency and cost. |

---

## 6. Option Comparison

| Dimension | Option 1 — RAG | Option 2 — Agentic Hybrid |
|---|---|---|
| Primary behavior | Retrieve → generate | Plan → call approved tools → combine → generate |
| Best for | Q&A, summaries, semantic similarity, follow-ups | Complex multi-step and cross-source questions |
| Current OpenSearch | Unchanged; current structured search remains available | Unchanged and exposed as one approved agent tool |
| Data source | Curated/enriched AI search content | Same AI search content plus current OpenSearch and approved lookups |
| Operational DB access | Read-only ingestion/data prep; no direct LLM DB access | No unrestricted DB access; purpose-built read-only tools only |
| Complexity | Moderate | Higher |
| Governance | Fixed retrieval path is easier to control | Requires tool permissions, orchestration controls, traceability |
| Cost drivers | Embeddings, vector storage/retrieval, LLM inference | All RAG costs plus additional LLM/tool calls |
| Recommended role | Near-term AI search option | Advanced evolution when multi-step needs justify it |

---

## 7. Recommended Direction

Present both architectures to FED as alternatives, not as an implementation commitment. The recommended sequence is to validate the business value and retrieval quality of RAG first, while ensuring its data model and APIs can be reused by an agentic layer later.

| Stage | Decision / output |
|---|---|
| Research / proposal (current Jira) | Approve target user use cases, data scope, architecture direction, security boundaries, and a cost ceiling. No AWS AI resources are created. |
| If Option 1 is approved | Build a controlled Dev evaluation over a representative approved search content set; measure retrieval quality, citation correctness, groundedness, latency, and cost. |
| Enrichment decision | If current domain JSON does not support target questions, enrich the AI copy or add AI-specific domain JSON. Do not redesign operational PostgreSQL solely for AI. |
| If agentic capability is justified | Reuse the RAG search content and expose current OpenSearch/read-only details as explicit tools. Add orchestration only for use cases that need multi-step behavior. |

### Why this is the best use of existing resources

- Preserves the proven current OpenSearch pipeline and UI behavior.
- Reuses existing denormalized domain knowledge instead of starting from raw tables.
- Allows AI coverage to grow independently through enrichment without destabilizing current search.
- Lets Option 2 reuse both the RAG search content and current OpenSearch, avoiding a second replacement search platform.
- Keeps expensive/complex agentic orchestration optional until a real user need requires it.

---

## 8. Security, Governance and Cost Posture

| Area | Proposal requirement |
|---|---|
| Data access | Read-only, least-privilege access to approved SPARKS data. No AI write path to operational records. |
| Network | Use approved DOT/AWS networking patterns for any future Dev implementation. Final VPC endpoint/private access requirements are architecture-review decisions. |
| Identity / authorization | Preserve SPARKS user authorization. AI retrieval must not expose records the requesting user is not allowed to see. |
| Grounding | Answers should include source identifiers/links. If sufficient evidence is not retrieved, the assistant should say so rather than fabricate. |
| Prompt / output controls | Apply content controls/guardrails appropriate to SPARKS data and log policy decisions without logging sensitive content unnecessarily. |
| Auditability | Record request ID, retrieved source keys, tool calls (for agentic), model response metadata, errors, and latency. |
| Cost | Research/design remains $0 AWS spend. Any implementation requires approval, usage limits, monitoring, and a defined stop/rollback condition. |

---

## 9. Decisions / Open Questions for FED

1. Which user questions are highest priority: semantic "find similar," summarization, cross-record comparison, or multi-step investigation?
2. For the first approved AI search content set, is reuse of current domain JSON sufficient, or should enrichment be included from the start?
3. What additional fields/relationships are missing from current JSON for the target AI use cases?
4. What is the approved vector-store / retrieval technology for the DOT environment? Keep this as a selection decision rather than assuming a specific product before sizing.
5. What freshness is required for AI search content — near the current indexing cadence, hourly, or daily?
6. How should Ask SPARKS appear in the UI: same search page, side panel, or explicit AI tab while retaining the existing pills/filters?
7. What source-key/linking contract will map AI citations back to the correct SPARKS record?
8. What Dev data set is approved for evaluation, and what data classifications/PII restrictions apply?
9. What evaluation thresholds must be met before any pilot can be considered successful?
10. Does FED want Option 1 only for the first evaluation, or should the design reserve agent tool contracts from the beginning without enabling agentic behavior?

---

## 10. Explicitly Deferred / Not Recommended for Initial Proposal

| Pattern | Reason to defer |
|---|---|
| Direct LLM / agent access to production PostgreSQL | Unnecessary coupling and governance risk for a search use case. Prefer curated retrieval and explicit read-only tools. |
| Blindly embedding every table/row | Relational rows lack business context and create noisy retrieval. Build domain documents instead. |
| Text-to-SQL against operational SPARKS | Requires substantially more security, SQL validation, authorization, workload isolation, and result-governance controls. |
| Fine-tuning a model for search | RAG/tool retrieval provides current SPARKS facts without the cost and lifecycle burden of training a domain model. |
| Replacing current OpenSearch pipeline | The existing search already solves exact/filtered retrieval. AI should extend it, not rebuild it without a proven business reason. |

---

## Appendix A — Source Grounding and Corrections

This refined proposal is based on the initial draft plus the actual SPARKS search logic reviewed during the analysis: the PostgreSQL `pushJsonData()` and `pushIndexToOpenSearchTable()` functions, the RDS-to-SQS Lambda, the SQS-to-OpenSearch Lambda, and the current OpenSearch/SQS/EventBridge configuration. Where the initial draft stated implementation assets or production-readiness that were not necessary to establish the proposal, those statements were removed or converted into future validation items.

### Key technical corrections applied

- Existing search documents are denormalized business JSON but can contain nested content; they should not be characterized as universally "flat."
- The SQS message carries identifiers/index metadata, not the full JSON payload; the downstream Lambda re-fetches `osj_json_data` by `osj_id`.
- A stable OpenSearch `_id` is computed by the consumer. The AI design should preserve a stable source key, but should not assume every upstream document already contains the same `uniqueId` field.
- RAG can be enhanced beyond the current search data by enriching the copied documents or adding AI-specific domain JSON. It is not permanently limited to today's OpenSearch schema.
- Tool selection and multi-step orchestration are reserved for the Agentic option; fixed RAG remains the simpler, deterministic retrieval architecture.
