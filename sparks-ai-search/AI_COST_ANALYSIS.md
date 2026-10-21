# SPARKS AI Search — AI Cost Analysis (Image / PDF Extraction)

**SB-6562 companion — measured-cost methodology for Claude on Amazon Bedrock**

> **Purpose:** DOT requires AI cost to be based on **actual, measured token usage**, not guesses. This document gives (a) the exact cost formula, (b) a worked business scenario for image/PDF → JSON extraction, (c) model/prompt/PDF cost drivers, and (d) a POC plan to capture real token counts from Bedrock before committing to a model.

> **Headline:** The business metric that matters is **cost per successfully extracted document** — not cost per million tokens. A cheaper model that produces more extraction errors (more manual review / retries) can cost more overall.

> **Closed, managed, governed — no open systems.** Per DOT requirements, this recommendation uses **only managed, enterprise-approved AWS services and vendor-hosted foundation models accessed through Amazon Bedrock.** We do **not** propose self-hosted / open-weight / open-source models (e.g. Llama, Mistral, Falcon on self-managed GPUs), community model servers, or any component that sits outside the approved AWS boundary. This keeps data in-account, keeps least-privilege IAM/KMS/CloudTrail governance intact, gives a single accountable vendor + support path, and makes cost a predictable, auditable **pay-per-token** line item rather than self-managed infrastructure. See §0.

---

## 0. Design & sourcing constraints (must hold for every option)

| Constraint | Requirement |
|---|---|
| **Models** | Vendor-hosted foundation models via **Amazon Bedrock only** (Anthropic Claude family). **No open-weight / open-source / self-hosted models.** |
| **Hosting** | Fully managed AWS services (Bedrock, Lambda, S3, OpenSearch Serverless, API Gateway, CloudWatch). **Nothing to patch, GPU-manage, or run as a community server.** |
| **Data boundary** | All data and inference stay **inside the approved AWS account/region**. Read-only access to approved SPARKS data; no third-party/open endpoints. |
| **Governance** | Least-privilege **IAM**, **KMS** encryption, **CloudTrail** audit, Bedrock Guardrails, model-invocation logging. |
| **Cost model** | **Pay-per-token** (measured), with **AWS Budgets hard cap** — not self-managed infrastructure with unpredictable scaling cost. |
| **Accountability** | Single vendor + AWS support path; no community-maintained dependencies in the critical path. |

Every cost figure and model choice below is evaluated **within** these constraints.

---

## How this fits Option 1 (RAG) and Option 2 (Agentic)

This cost model is **not a separate workstream** — it prices the AI work that both proposal options depend on. Image/PDF → JSON extraction is part of **AI Data Prep**, which produces the curated search content both options retrieve from.

| | **Option 1 — RAG** | **Option 2 — Agentic** |
|---|---|---|
| Where extraction cost lands | **AI Data Prep** — extract/enrich approved documents (incl. image/PDF → JSON) into the curated search content, **mostly one-time + on change** | Same AI Data Prep (reused) — **no extra extraction cost**; Option 2 adds cost only in orchestration |
| Ongoing model cost | **1 Claude answer call per question** → ~1–3¢/question | **Several Claude calls per question** (plan → tools → answer) → ~4–10¢/question |
| Embedding cost | One-time per document + re-embed on change | Reuses Option 1's embeddings — no additional embedding cost |
| Cost driver to watch | Document/PDF size during prep; output JSON size | Same, **plus** number of agent tool-calls/turns per question |
| Model tiering applies | Yes — Haiku for routine extraction, Sonnet baseline, Opus only for hard docs | Same tiering, plus a cheaper model for intent/classify steps and the stronger model only for the final grounded answer |

**So the two cost layers are:**
1. **Prep/extraction (shared by both options)** — the image/PDF → JSON scenario in §2–§7. Dominated by document size and model/prompt efficiency; mostly one-time + incremental.
2. **Per-question inference** — Option 1 is a single call (cheap); Option 2 is multi-call (a few × more). Covered in §3 and the per-question figures.

Everything below quantifies layer 1 (the extraction/prep cost) with a measured methodology; the per-question figures for Option 1 vs Option 2 are summarized in §3 and in the deck's cost slide.

---

## 1. The cost formula

```
Total Cost ($) = [ N × (I × Pi + O × Po) ] / 1,000,000
```

| Symbol | Meaning |
|---|---|
| `N` | Number of extraction requests |
| `I` | Input tokens per request (document/image tokens **+** prompt tokens) |
| `O` | Output tokens per request (the extracted JSON) |
| `Pi` | Price per **million input** tokens |
| `Po` | Price per **million output** tokens |

**All token counts and prices below are illustrative planning assumptions.** Actual cost depends on image size, PDF page count/mode, model pricing, caching, retries, and Bedrock configuration. The POC in §6 replaces these with measured values.

---

## 2. Business scenario — image/PDF processing

Application extracts structured fields (manufacturer, model, year, VIN, investigation details, …) into JSON for downstream processing.

### Volume

| Metric | Value |
|---|---|
| Images per hour | 100 |
| Images per 8-hour business day | 800 |
| Images per month (22 business days) | 17,600 |

### Token assumptions (illustrative)

| Component | Tokens |
|---|---|
| Image + extraction prompt (input) | 1,700 |
| Generated structured JSON (output) | 300 |

---

## 3. Model cost comparison (same 1,700 in / 300 out per request)

Illustrative Bedrock/Anthropic-style pricing. **Confirm live rates for your Bedrock account/region before quoting.**

| Model | Input $/1M | Output $/1M | Per hour (100) | Per month (17,600) |
|---|---|---|---|---|
| **Claude Haiku** | $1 | $5 | $0.32 | **$56.32** |
| **Claude Sonnet** (baseline) | $2 | $10 | $0.64 | **$112.64** |
| **Claude Opus** | $4 | $20 | $1.28 | **$225.28** |

**Reading it:**
- **Sonnet** baseline ≈ **$0.64/hr → ~$113/month** at this volume.
- **Haiku** ≈ **half** of Sonnet (~$56/month) — if accuracy is comparable on routine documents.
- **Opus** ≈ **2× Sonnet** (~$225/month) — only justified if it *materially* reduces extraction errors / manual review. For routine image/PDF extraction, Opus is usually **not** worth the premium.

> **Recommendation:** Keep **Sonnet as the baseline**; route routine/clean documents to **Haiku**; reserve **Opus** (or Sonnet) for complex documents or failed validations. Decide with data, not defaults.

---

## 4. Does the prompt matter? (and PDF vs image)

Yes — but the manager's "same prompt skyrockets cost" concern is only **partly** correct. What drives cost is **total tokens**, not prompt wording alone. Sharing one schema between PDFs and images is fine; the big levers are **document size** and **output volume**.

### Cost drivers, ranked

| Factor | Cost impact | Recommendation |
|---|---|---|
| **Sending a whole multi-page PDF** | **Largest** — a 20-page PDF ≫ a single image | Extract embedded text / select only relevant pages |
| Large JSON response | High (output tokens priced higher) | Return **only required fields** |
| Long prompt repeated every request | Moderate (billed each request) | Keep instructions concise & reusable |
| High-resolution images | Moderate | Use appropriate resolution |
| Repeated examples in prompt | Moderate | Only examples that improve accuracy |
| Retrying failed extractions | Adds up | Validate + retry **selectively** |
| Same prompt for PDF & image | **Not inherently expensive** | Separate only the document-specific instruction |

### Worked example — prompt length (single image, 1,500 doc tokens, 300 out)

| | Optimized prompt | Long generic prompt |
|---|---|---|
| Image (document) tokens | 1,500 | 1,500 |
| Prompt tokens | 200 | 2,000 |
| **Total input** | **1,700** | **3,500** |
| Output tokens | 300 | 300 |
| Cost / 100 requests | **$0.64** | **$1.00** |
| Monthly (17,600) | **$112.64** | **$176.00** |

→ An unnecessarily long prompt raises cost **~56%** here. But a 20-page PDF can cost far more than any single image even with an identical prompt — **document size dominates.**

### POC comparison — image vs 10-page PDF (illustrative)

| Metric per request | Image: long | Image: short | PDF: long | PDF: short |
|---|---|---|---|---|
| Document tokens | 1,500 | 1,500 | 15,000 | 15,000 |
| Prompt tokens | 2,000 | 200 | 2,000 | 200 |
| Output tokens | 500 | 300 | 500 | 300 |
| **Total cost / request** | **$0.0120** | **$0.0064** | **$0.0390** | **$0.0334** |

- **Images:** optimizing the prompt saves **~47%** (prompt+output are a big share of a small request).
- **PDFs:** optimizing the prompt saves only **~14%** — because the 15,000 **document** tokens dominate. (That 15,000 is an assumption; real PDF usage depends on pages, images, layout, and processing mode.)

**Takeaway:** For PDFs, the highest-impact question is not prompt wording — it is *"are we sending the entire multi-page PDF when we only need 1–2 pages?"*

---

## 5. What matters most in the SPARKS Lambda architecture

Because extraction runs **S3 → Lambda → Claude on Bedrock → JSON**, the biggest cost levers are **what Lambda sends, how many times it invokes Claude, and whether extraction succeeds first try.**

**Optimized flow (see diagram `AI_Cost_Extraction_Flow.pdf`):**

```
S3 (PDF / image uploaded)
  → Lambda: inspect file type, size, page count; extract embedded text where appropriate; select relevant pages
      ├─ Image route: one image + concise image prompt (appropriate resolution)
      └─ PDF route:   relevant text/pages + PDF-specific instruction
  → Amazon Bedrock → Claude: shared JSON schema; return only required fields; record inputTokens/outputTokens/modelId
  → Lambda: validate JSON → save → log cost; retry/escalate ONLY invalid or low-confidence cases
```

### Six things to check in the existing Lambda first

| # | Check in Lambda | Why it matters |
|---|---|---|
| 1 | Does Lambda send the **entire** PDF? | A 30-page PDF can consume far more tokens than one image |
| 2 | Does Lambda call Claude **once or many times** per doc? | Multiple calls multiply token charges |
| 3 | Does it reuse one **large** prompt every request? | Repeated instructions billed each request unless caching applies |
| 4 | Are PDFs converted into **page images**? | Sending every rendered page can greatly increase image tokens |
| 5 | How large is the returned **JSON**? | Output tokens are priced higher than input |
| 6 | What happens on **errors/timeouts**? | Retries add Bedrock charges + Lambda runtime |

Also track **Lambda duration + memory** — infra cost — though model inference usually dominates for extraction workloads.

---

## 6. POC — capture REAL token counts (the DOT ask)

**Objective:** determine **cost per successfully processed document** and pick the most cost-efficient model **without compromising data accuracy.**

**Method:**
1. Start with **10 images + 10 PDFs**, expand to **50–100 representative documents**.
2. Hold **model ID, documents, temperature, processing mode, and required JSON fields identical** between prompt versions (existing vs optimized).
3. Capture Bedrock Converse usage per request and log to CloudWatch (no sensitive content / PII):

```python
usage = response["usage"]
print("Input tokens:",  usage["inputTokens"])
print("Output tokens:", usage["outputTokens"])
print("Latency ms:",    response["metrics"]["latencyMs"])
```

**Per-request log record (sample values, not measured):**
```json
{
  "documentType": "PDF",
  "pageCount": 20,
  "modelId": "configured-model-id",
  "promptVersion": "optimized-v1",
  "bedrockCalls": 1,
  "inputTokens": 12000,
  "outputTokens": 350,
  "latencyMs": 2800,
  "extractionValid": true,
  "retryCount": 0
}
```

**Compare across Sonnet vs Haiku (and Opus on hard docs only):** input tokens, output tokens, extraction accuracy, retry rate, latency, and **total cost per *successful* document.**

**Strongest POC outcome:** *same extraction accuracy + fewer tokens + fewer retries = verified cost optimization.*

> **Prompt caching note:** Bedrock supports prompt caching for eligible models and can cut cost when large identical prompt content is reused — but it has per-model minimum-token thresholds and cache-write costs, so it may not help a short ~200-token prompt. Evaluate against measured usage.

---

## 7. Recommended extraction prompt design

One **shared schema**, plus a short **document-type-specific** instruction.

**Common instructions**
```
Extract vehicle-related information from the supplied document.
Return ONLY valid JSON with these fields:
{ "manufacturer": null, "model": null, "year": null, "vin": null, "investigation_number": null }
Rules:
- Use only information explicitly present.
- Use null for missing or unreadable fields.
- Do not guess. Do not add explanations or Markdown.
```

**Image add-on:** `Read the supplied image, including visible labels, handwriting, and tables where legible.`

**PDF add-on:** `Extract information across the relevant PDF pages. Avoid duplicating repeated headers or values.`

---

## 8. Recommendations for the team / FED

1. **Measure before quoting.** Run the POC; replace every illustrative number here with Bedrock-measured token counts and current account pricing.
2. **Baseline Sonnet, test Haiku for routine docs, reserve Opus for hard docs** — tiered routing, decided by accuracy data.
3. **Attack PDF page volume first** — the single largest lever; don't send whole multi-page PDFs when 1–2 pages suffice.
4. **Return only required JSON fields**, validate, and retry selectively.
5. **Track cost per *successful* document**, not cost per token — accuracy and retries are part of true cost.
6. **Set an AWS Budgets hard cap** and dashboard input/output tokens, latency, retry rate, and cost per document.

> **Pricing verification:** Model prices change — verify the current Anthropic/Bedrock rates for your region and model IDs at approval time. The figures here are a reproducible *method*, not a quote.
