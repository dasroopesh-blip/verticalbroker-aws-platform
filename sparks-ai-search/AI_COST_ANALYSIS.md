# SPARKS AI Search — AI Cost Model (Option 1 & Option 2)

**SB-6562 companion — measured, defensible cost estimate for Claude on Amazon Bedrock**

> **Scope of this cost model:** the **actual SPARKS AI Search workload** — natural-language / semantic search over the text documents SPARKS already produces (the `open_search_json` content). It is **not** an image/PDF OCR workload. Cost = (1) a **one-time embedding** to build the vector index + (2) **per-question model inference** for Option 1 (RAG) and Option 2 (Agentic), + (3) a small fixed monthly AWS infrastructure band.

> **Confidence:** This is a **planning estimate targeted at ~70–90% accuracy** for monthly and annual spend. The remaining variance comes from final question volume, average context size per question, and live Bedrock rates — all pinned down in the Dev pilot (§6). It is a reproducible **method**, not a quote.

> **Closed, managed, governed — no open systems.** Per DOT requirements this uses **only managed AWS services and vendor-hosted foundation models via Amazon Bedrock (Anthropic Claude).** No self-hosted / open-weight / open-source models, no community model servers, nothing outside the approved AWS account. Cost is a predictable, auditable **pay-per-token** line item with an AWS Budgets hard cap.

---

## 0. The three cost components

| # | Component | When it is incurred | Relative size |
|---|---|---|---|
| 1 | **Embedding (build vector index)** | **One-time** at setup + incremental on changed documents | **Tiny** (one-time) |
| 2 | **Per-question model inference** | Every user question | **Main ongoing driver** |
| 3 | **Fixed AWS infrastructure** | Monthly (vector store min capacity, Lambda, S3, logs) | **Small, flat band** |

Option 1 and Option 2 **share** components 1 and 3. They differ only in component 2 (Option 2 makes several model calls per question).

---

## 1. The formula

```
Model Cost ($) = [ N × (I × Pi + O × Po) ] / 1,000,000
```
`N` = number of calls · `I` = input tokens/call · `O` = output tokens/call · `Pi`/`Po` = price per **million** input/output tokens.

**Illustrative Bedrock rates used below (confirm live at approval):**

| Item | Input $/1M | Output $/1M |
|---|---|---|
| Amazon **Titan Text Embeddings v2** | $0.02 | — |
| Claude **Haiku** | $0.80 | $4.00 |
| Claude **Sonnet** (baseline) | $3.00 | $15.00 |
| Claude **Opus** (hard cases only) | ~2× Sonnet | ~2× Sonnet |

---

## 2. Component 1 — one-time embedding (both options)

Turn each SPARKS document into a vector once; re-embed only changed documents afterward.

| Documents | Avg tokens/doc | Total tokens | One-time embedding cost |
|---|---|---|---|
| 50,000 | 500 | 25 M | **~$0.50** |
| 100,000 | 500 | 50 M | **~$1.00** |
| 200,000 | 600 | 120 M | **~$2.40** |

→ **Embedding is effectively free at these volumes (a few dollars, once).** This corrects the earlier "tens of dollars" wording. The real one-time work is engineering effort, not token cost.

---

## 3. Component 2 — per-question inference (Option 1 vs Option 2)

Assumptions per question: **~4,000 input tokens** (retrieved context + question + instructions) and **~400–500 output tokens** (grounded answer). Option 2 runs **~3 model turns** (plan → tool use → answer).

| | Model | Calls/question | Cost/question (Sonnet) | Cost/question (Haiku) |
|---|---|---|---|---|
| **Option 1 — RAG** | Claude | 1 | **~$0.020 (≈2¢)** | ~$0.005 |
| **Option 2 — Agentic** | Claude | ~3 | **~$0.054 (≈5¢)** | ~$0.014 |

→ **Option 2 ≈ 2.5–3× Option 1 per question** (more LLM turns). Query-embedding cost per question is negligible (fractions of a cent).

---

## 4. Monthly estimate (Dev-pilot volumes, Sonnet)

Model inference only; add the fixed infra band from §5. 22 business days/month.

| Volume | Option 1 — RAG /mo | Option 2 — Agentic /mo |
|---|---|---|
| 100 questions/day (2,200/mo) | **~$43** | **~$119** |
| **200 questions/day (4,400/mo) — baseline** | **~$86** | **~$238** |
| 500 questions/day (11,000/mo) | **~$214** | **~$594** |

---

## 5. Fixed AWS infrastructure (monthly band)

Managed services that run regardless of question volume (kept minimal in Dev):

- **OpenSearch Serverless** vector collection — minimum OCU capacity (the main fixed item)
- S3 (search content), Lambda (extractor + Ask API), API Gateway, CloudWatch, KMS

**Estimated band: ~$150–$400/month in Dev** (dominated by the vector store's minimum capacity; scales with load). Confirm against your account's AOSS minimums.

---

## 6. All-in monthly & annual (200 q/day baseline)

Model inference **+** fixed infra band. This is the number to quote, with the accuracy caveat.

| Option | Model/mo | + Infra/mo | **All-in / month** | **All-in / year** |
|---|---|---|---|---|
| **Option 1 — RAG** | ~$86 | $150–$400 | **~$240–$490** | **~$2,800–$5,800** |
| **Option 2 — Agentic** | ~$238 | $150–$400 | **~$390–$640** | **~$4,700–$7,700** |

**One-line summary:**
> *"At a 200-question/day Dev pilot: **Option 1 ≈ $240–$490/month (~$3–6K/year)**; **Option 2 ≈ $390–$640/month (~$5–8K/year)**; plus a one-time embedding of a few dollars. $0 today — spend starts only after FED approval, under an AWS Budgets hard cap. Estimate targeted at 70–90% accuracy, confirmed by the pilot."*

---

## 7. Why this is ~70–90% accurate (and what moves it)

| Driver | Effect on cost | How we pin it down |
|---|---|---|
| **Questions per day** | Linear — the biggest swing | Measure actual pilot usage |
| **Context tokens per question** (how many chunks retrieved) | Linear on input cost | Cap `top_k` + context length; measure |
| **Answer length** (output tokens) | Output priced higher | Constrain response format; measure |
| **Option 2 turns per question** | ~2–4× multiplier | Loop cap on the agent; measure |
| **Live Bedrock rates / region** | Direct | Confirm at approval |
| **Vector store min capacity** | Fixed band | Confirm AOSS minimums for the region |
| **Model mix (Haiku vs Sonnet)** | Haiku ~¼ of Sonnet | Tiered routing decided by accuracy |

The ±band above already reflects these; the pilot replaces the band with measured values.

---

## 8. Cost-control levers (designed in)

- **AWS Budgets hard cap** — spend physically cannot exceed the agreed ceiling.
- **Tiered models** — Haiku for simple/classify steps, **Sonnet baseline**, Opus only for hard cases (Opus ≈ 2× Sonnet; justify with accuracy data).
- **Cap `top_k` and context length** per question (biggest per-question lever).
- **Return only required fields / concise answers** (output tokens are priced higher).
- **Re-embed only changed documents** (keeps embedding at pennies).
- **Option 1 first** — fewer LLM turns than Option 2; adopt Option 2 only where multi-step value is proven.
- **Prompt caching** (Bedrock, eligible models) if large identical prompt content is reused — evaluate against measured usage; may not help short prompts.

---

## 9. Measure-before-quote (the DOT ask)

Replace every illustrative number with Bedrock-measured values in the Dev pilot:

1. Run a representative question set for **Option 1** (and later Option 2) over a realistic Dev search-content set.
2. Capture Bedrock Converse usage per call to CloudWatch (no PII):
```python
usage = response["usage"]
print("Input tokens:",  usage["inputTokens"])
print("Output tokens:", usage["outputTokens"])
print("Latency ms:",    response["metrics"]["latencyMs"])
```
3. Record per question: `inputTokens`, `outputTokens`, model id, number of LLM turns (Option 2), retries, latency.
4. Compute **cost per *answered* question** and extrapolate to monthly/annual at the agreed volume.
5. Compare **Sonnet vs Haiku** on answer quality + cost; set the tiered-routing policy.

**Metric that matters: cost per *good* answer** — a cheaper model that produces worse/ungrounded answers (more retries, lost trust) is not cheaper overall.

---

## Appendix — document (image/PDF) extraction (only if a future enrichment needs it)

The current SPARKS AI Search workload is **text search**, so OCR/vision extraction is **out of scope** for Option 1/2 costing. *If* a future enrichment adds extracting fields from scanned documents/images into the search content, the same formula applies with these notes:

- Cost is dominated by **document size** (a 20-page PDF ≫ one image), then output JSON size, then prompt length.
- Use **managed Claude on Bedrock** (no open/self-hosted OCR); extract embedded text first, send only relevant pages.
- Measure `inputTokens`/`outputTokens` per document and track **cost per successfully extracted document**.

This is noted for completeness only; it is **not** part of the Option 1/2 baseline cost above.
