# Search Excellence: relevance, ranking, efficiency, and the AI agent

A reference design for making enterprise search **best-in-class** on AWS —
built for financial-services teams and AWS partners. It shows how three AWS
services combine to turn a search box into a trustworthy answer engine:

- **Amazon Bedrock** — embeddings (Titan V2) + reasoning/agent (Claude Sonnet)
- **Amazon OpenSearch** — hybrid retrieval (vector k-NN + keyword BM25)
- **Amazon SageMaker** — a cross-encoder reranker for ranking precision

The design is organized around four pillars.

---

## Pillar 1 — Relevance: are the right documents found?

| Technique | Where | What it buys you |
|---|---|---|
| **Hybrid retrieval** (BM25 + vector) | OpenSearch | Exact-term precision *and* semantic recall |
| **Query understanding** | Bedrock/Claude | Rewrites the prompt + extracts filters (ticker, form, section) |
| **Metadata filtering** | OpenSearch term filters | "Only NVDA 10-K, 2024, Item 1A" |
| **Relevance measurement** | `evaluation/` | Recall@k, MRR, nDCG — relevance you can *prove* |

The differentiator: **relevance is measured, not asserted.** The evaluation
harness scores retrieval against a labeled golden set, so every change is
quantified.

## Pillar 2 — Ranking: is the best result first?

A multi-stage funnel — cheap-and-broad first, expensive-and-precise last:

```
1000s of candidates
   │ Stage 1 RETRIEVE  (OpenSearch: BM25 + kNN)      cheap, fast
   ▼  ~50
   │ Stage 2 FUSE      (Reciprocal Rank Fusion)      combine signals
   ▼  ~50
   │ Stage 3 RERANK    (SageMaker cross-encoder)     precise, on shortlist only
   ▼  top ~10
Final ranking
```

**Why a cross-encoder reranker wins:** first-stage retrieval embeds query and
document *separately*. A cross-encoder reads the **(query, passage) pair
together**, so it captures interactions — exact overlap, negation, entity
resolution — that vector similarity misses. It only runs on the ~50 shortlist,
so the precision gain is cheap. This is where **SageMaker earns its place**
(host, and optionally fine-tune on your domain, a cross-encoder such as a
BGE/MS-MARCO reranker).

Implemented in `search/reranker.py` (SageMaker + local fallback) and slotted
into `search/service.py::hybrid_search`.

## Pillar 3 — Efficiency: fast and cost-effective at scale?

| Concern | Lever |
|---|---|
| Latency | HNSW ANN vector index (approximate, ~O(log N)); rerank only the shortlist |
| Throughput | Embed once at ingest (never re-embed); async via SQS + Lambda |
| Cost | Cheap first-stage retrieval; reranker on ~50 not the whole corpus; scale-to-zero |
| Tunable | HNSW `ef_search`/`m`, Titan dimensions (256/512/1024) trade recall vs speed/size |
| Observable | p50/p95 latency, cost/query, and cache-hit metrics as first-class signals |

Efficiency is **engineered and monitored**, not hoped for.

## Pillar 4 — The AI agent: the differentiator

The Bedrock/Claude agent (`agent/agent.py`) turns search results into answers:

- **Plans** retrieval — picks keyword vs semantic vs hybrid, applies filters
- **Understands** the query — rewrite/expand + metadata extraction
- **Synthesizes** a grounded, **cited** answer instead of a list of links
- **Guardrails** — grounding, citations, and *no investment advice* (compliance)
- **Tenant-sandboxed** — can only ever touch the caller's tenant data

The customer value: users stop scrolling 50 hits and get a cited, auditable
answer.

---

## How the three AWS services divide the work

```
Ingest:  SEC data → SQS → Lambda → Bedrock(Titan embed) → OpenSearch(index)

Query:   User → Bedrock(Claude: understand + plan)
              → OpenSearch (retrieve: kNN + BM25, RRF fuse)   Stage 1
              → SageMaker (cross-encoder rerank)              Stage 2
              → Bedrock(Claude: synthesize cited answer)      Stage 3
              → CloudWatch (latency + cost + relevance)
```

- **Bedrock** = intelligence (embeddings, reasoning, query understanding)
- **OpenSearch** = the search engine (vector + keyword + fast ANN)
- **SageMaker** = custom ranking ML (the cross-encoder reranker)

Everything is AWS-native and provisioned with Terraform. Reranking is opt-in
(`FA_ENABLE_RERANKING`, `enable_reranker` in Terraform); with it off, the system
falls back to the fused ranking, so the endpoint cost is only incurred when you
want the extra precision.

## Proving the uplift

`evaluation/harness.py::compare_reranking` runs the same labeled queries with
reranking OFF vs ON and reports Recall@k / MRR / nDCG for each — the before/after
evidence that the SageMaker reranker improves ranking quality.
