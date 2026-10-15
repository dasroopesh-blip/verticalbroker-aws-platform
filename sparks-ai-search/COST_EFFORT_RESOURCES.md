# SPARKS AI Search — Cost, Effort, Resources & Complexity (for NARB internal review)

> **Jira:** SB-6562 — *research & identify options to enable prompt searching.*
> **Acceptance criteria:** ER Diagram · Research Content · Proposal Documents · **NO COST in AWS**.
> **Hard constraint from the ticket:** Bedrock is available in our AWS account, but **we incur ZERO cost until FED Lead approves** use of an AI tool in the Dev environment. Everything below is a **research/proposal estimate only** — nothing is provisioned yet.

---

## 0. NO-COST-NOW statement (read first)

This story is **research and documentation only**. To satisfy "NO COST in AWS":

- **Nothing is deployed.** No Bedrock model invoked, no OpenSearch vector index created, no Lambda deployed, no S3 search content written.
- All cost figures below are **forward estimates** to inform the FED Lead's approval decision.
- Spend begins **only after** FED Lead approval, and even then starts in **Dev** with a capped, measured pilot (see §7 phasing).
- We can present cost as **"$0 today; estimated $X/month in Dev pilot after approval."**

---

## 1. The two options (what NARB is approving to propose)

| | **Option 1 — Generative AI / RAG** | **Option 2 — Agentic Hybrid** |
|---|---|---|
| User experience | "Ask SPARKS" chat box | Same chat box |
| Behavior | Retrieve from curated search content → Claude generates grounded answer + citations | Agent plans → calls approved tools (existing OpenSearch, semantic search, record lookups) → generates |
| Reuses current OpenSearch | As the exact/filter path | As an agent **tool** |
| Net-new AWS components | Bedrock KB, vector index, S3 search content, extractor Lambda, orchestrator Lambda, API GW | All of Option 1 **plus** Bedrock Agent + tool Lambdas |
| Relative complexity | **Medium** | **High** |
| Recommended sequencing | **Build first (MVP)** | **Evolution of Option 1** |

Both are delivered as **one chat box**; the existing structured search is **unchanged**.

---

## 2. Resource list (AWS + non-AWS)

### Option 1 — RAG
| Resource | Purpose | New? | Cost driver |
|---|---|---|---|
| Amazon Bedrock — embeddings model (e.g. Titan Text Embeddings) | Vectorize search content + queries | New (approval-gated) | per 1K input tokens |
| Amazon Bedrock — Claude (LLM) | Generate grounded answers | New (approval-gated) | per 1K input + output tokens |
| Amazon Bedrock Knowledge Base | Managed chunk/embed/retrieve | New | mostly embedding + vector store |
| Vector store — **OpenSearch vector index** (recommended) | Store/query embeddings | New index on **existing** domain | cluster capacity / OCU |
| Amazon S3 | Curated AI search content (one object per `uniqueId`) | New bucket | pennies (storage + requests) |
| AWS Lambda — AI extractor/enricher | Read `osj_json_data` read-only → S3 | New | per-invocation (cheap) |
| AWS Lambda — Ask-SPARKS orchestrator | RAG query handler | New | per-invocation (cheap) |
| Amazon API Gateway | `/ask` endpoint | New | per request (cheap) |
| Amazon EventBridge | Search-content refresh schedule | Reuse pattern | negligible |
| Bedrock Guardrails | Safety/grounding | New | per text unit (small) |
| CloudWatch | Logs/metrics | Reuse | negligible |

### Option 2 — Agentic (adds to Option 1)
| Resource | Purpose | New? | Cost driver |
|---|---|---|---|
| Amazon Bedrock Agent (or AgentCore) | Plan + tool orchestration | New | extra LLM turns (reasoning loop) |
| Tool Lambdas: `openSearchSearch`, `semanticSearch`, `getInvestigation/getVehicle/getEquipment` | Approved read-only tools | New | per-invocation (cheap) |
| IAM tool allow-listing + role scoping | Governance | New | none |

**Non-AWS / people:** 1 engineer (backend/data) + part-time solution architect; FED Lead approval; SME time for the evaluation golden set.

---

## 3. LLM & vectorization — the decisions NARB asked about

### LLM
- **Model:** Claude on Amazon Bedrock (already the house standard; available in our account).
- **Why:** no model hosting to manage; pay-per-token; strong grounding/citation behavior; guardrails native.

### Vectorization — **do we need embeddings? YES** (for semantic/NL search)
Keyword search (today's OpenSearch) matches terms; it cannot do "find similar failures" or natural-language questions. That requires **embeddings** (vectorization) + a **vector store**.

### Vector store — **is pgvector the answer? Our recommendation: NO (not for v1).**
Three candidates evaluated:

| Store | Verdict | Rationale |
|---|---|---|
| **OpenSearch vector index** | ✅ **Recommended** | SPARKS **already runs OpenSearch** (sparks-stage). Add a k-NN vector index on the same domain → one system to run/govern, reuses existing ops, supports hybrid (keyword + vector) + metadata filters. |
| **pgvector (on RDS PostgreSQL)** | ⚠️ Possible, not preferred | Co-locates vectors with the source DB and is SQL-native, **but** adds vector load to the **operational** RDS, needs the `pgvector` extension enabled (DBA + change control), and splits search across two engines (OpenSearch for keyword, Postgres for vector). Adds operational risk to a production DB for no clear win. |
| **S3 Vectors** | ⚠️ Future option | Cheap at rest, serverless; newer, fewer hybrid/filter features. Revisit for cost at scale. |

**Bottom line for the deck:** *"We do need vectorization for semantic search. We recommend an OpenSearch vector index (reusing the engine SPARKS already operates) rather than enabling pgvector on the production RDS. pgvector is viable but adds load and change-control risk to the operational database."*

---

## 4. Token & cost model (estimate only — $0 until approved)

> Illustrative. Replace rate placeholders with current Bedrock Dev-account rates at approval time. Figures assume a **Dev pilot**, not production scale.

### Search-content sizing (drives one-time embedding cost)
- Domains: 8 (5 core + 3 legacy). Assume **~N documents** total (confirm via `SELECT count` per index).
- Embedding is **one-time per document** + **re-embed on change** (incremental).
- Token estimate per doc: short structured fields + `failure_desc`/`prob_summary` free text ≈ **~300–800 tokens/doc** (many docs far smaller; nulls common).

**One-time embedding cost ≈** `total_docs × avg_tokens_per_doc / 1000 × embedding_rate_per_1K`.
*Example shape:* 50,000 docs × 500 tokens = 25M tokens = 25,000 × (embedding rate per 1K). At typical embedding rates this is **tens of dollars, one time** — small.

### Per-query cost (ongoing)
| Component | Tokens (typical) | Notes |
|---|---|---|
| Query embedding | ~20–50 in | tiny |
| Retrieved context into Claude | ~2,000–6,000 in | top-k chunks (k≈8) |
| Claude output (answer + citations) | ~300–800 out | grounded summary |
| **Option 2 extra** | +1–4 reasoning turns | agent loop multiplies LLM calls ~2–4× |

**Per-query cost ≈** `(context_in + out_tokens)/1000 × claude_rate`. Order-of-magnitude: **cents per query** for Option 1; **a few × that** for Option 2 (more LLM turns).

**Monthly Dev pilot ≈** `queries/day × 30 × per-query cost` + small vector-store capacity + negligible Lambda/S3.
*Example shape:* 200 queries/day × 30 × $0.01–0.03 ≈ **$60–180/month** in Dev + vector index capacity. **Confirm with live Bedrock rates at approval.**

### Cost levers (how we keep it low)
- Cache embeddings; **re-embed only changed docs** (the outbox already flags changes).
- Cap `top_k` and context length.
- Start Dev-only, capped request volume.
- Option 1 before Option 2 (fewer LLM turns = lower token spend).

---

## 5. What it takes to go from current → AI search

| Step | Option 1 | Option 2 |
|---|---|---|
| 1. Read-only tap on `open_search_json` | ✅ | ✅ |
| 2. Curated S3 search content (reuse `uniqueId`) | ✅ | ✅ |
| 3. Embeddings + vector index (OpenSearch) | ✅ | ✅ |
| 4. Bedrock KB retrieval | ✅ | ✅ |
| 5. Claude generation + citations | ✅ | ✅ |
| 6. "Ask SPARKS" chat box in existing UI | ✅ | ✅ |
| 7. Bedrock Agent + approved tools | — | ✅ |
| 8. Golden Q&A eval set + thresholds | ✅ | ✅ |

**Unchanged throughout:** both existing Lambdas, `SearchQueue.fifo`, `pushJsonData`, `pushIndexToOpenSearchTable`, all `json_*_rec()` builders, the outbox schema/flags, existing indexes, and the current pills/filters/keyword UI.

---

## 6. Effort & complexity (development-wise)

> T-shirt sizing for the Dev pilot. One engineer + part-time SA. **Estimates, not commitments.**

| Workstream | Option 1 | Option 2 (additive) | Complexity |
|---|---|---|---|
| Read-only extractor → S3 search content | S (reuse) – M (enrich) | — | Low |
| Vector index + Bedrock KB wiring | M | — | Medium |
| Orchestrator Lambda + `/ask` API | M | — | Medium |
| Chat box in existing UI | M | — | Medium (FE contract TBD) |
| Agent + tool Lambdas + allow-listing | — | M–L | High (orchestration, guardrails) |
| Evaluation (golden set + thresholds) | M | +S | Medium |
| **Rough order (Dev pilot)** | **~3–5 weeks** | **+2–4 weeks** | — |

Complexity drivers: FE integration contract; search content freshness strategy; agent tool-calling + guardrails (Option 2); evaluation rigor for a federal system.

---

## 7. Phasing (keeps cost gated)

| Phase | Spend | Gate |
|---|---|---|
| **This story (SB-6562)** | **$0** | Research + proposal + ER diagram only |
| **FED Lead approval** | — | Approve AI-tool use in Dev |
| **Phase 1 — RAG MVP (Dev)** | capped Dev pilot | Reuse-only search content, measure tokens/cost |
| **Phase 2 — Enrich + evaluate** | small | Golden set + acceptance thresholds |
| **Phase 3 — Agentic (Option 2)** | higher (more LLM turns) | Only if multi-step value is proven |

---

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Unbounded token/cost | Dev-only cap; re-embed only changed docs; cap top_k; Option 1 first |
| Production DB impact | **Don't** use pgvector on prod RDS; use OpenSearch vector index |
| Hallucination (federal context) | Grounded RAG + citations via `uniqueId`; Bedrock Guardrails; eval thresholds before go-live |
| Scope creep to "replace search" | Explicit: existing OpenSearch keyword/filter search is **unchanged** |
| Data governance | Read-only access; curated copy; least-privilege IAM |

---

## 9. The "sell" — one paragraph for NARB

> SPARKS can add a natural-language **"Ask SPARKS"** experience by **reusing what it already has** — the OpenSearch engine and the denormalized, `uniqueId`-keyed documents it already builds — and layering Amazon Bedrock (Claude) on top via RAG (**Option 1**), with an optional agentic evolution (**Option 2**). We recommend an **OpenSearch vector index** over enabling **pgvector** on the production database, keeping operational risk low. The existing structured search is **untouched**. This story delivers the research, ER diagram, and proposal at **zero AWS cost**; spend begins only after FED Lead approval, starting with a **capped Dev pilot** estimated in the **low tens-to-low-hundreds of dollars per month**, with clear levers to control token usage.

---

## 10. Numbers to confirm before the FED presentation
- `SELECT count(*)` per index (total search-content size → embedding cost).
- Current Bedrock Dev-account rates (embedding per 1K; Claude in/out per 1K).
- Expected query volume/day in Dev.
- OpenSearch vector capacity (OCU/instance) for the pilot.
- FE integration contract for the chat box.
