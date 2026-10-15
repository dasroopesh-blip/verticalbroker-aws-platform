# SPARKS AI Search — Production Design (E2E, Prod-Ready)

> Elevates Option 1 (RAG) and Option 2 (Agentic) from research to a **deployable, operable** design.
> Companion to `HLD.md`, `LLD.md`, `COST_EFFORT_RESOURCES.md`. **Independent of EDMAS** — SPARKS owns the full stack.
> IaC: Terraform (see `infra/terraform/`). Everything is gated behind FED Lead approval (no spend until then).

---

## 0. Locked architecture decisions (no longer "TBD")

| Decision | Choice | Rationale |
|---|---|---|
| LLM | **Claude on Amazon Bedrock** (Sonnet-class for prod answers; Haiku-class for cheap classify/followups) | House standard; pay-per-token; strong grounding |
| Embeddings | **Amazon Titan Text Embeddings v2** on Bedrock | Native to Bedrock; low cost per 1K tokens |
| Vector store | **Amazon OpenSearch Serverless (AOSS) vector collection** — separate from the `sparks-stage` search domain | Isolates AI load from production search; k-NN + metadata filters; no pgvector on prod RDS |
| Retrieval | **Amazon Bedrock Knowledge Base** (managed chunk/embed/sync) over the S3 search content | Managed ingestion; fewer moving parts than custom |
| Search-content store | **Amazon S3** (versioned, SSE-KMS) `s3://sparks-ai-search-content-<env>/<domain>/<uniqueId>.json` | Durable, cheap, auditable |
| Data tap | **Read-only** extractor over `sparks.open_search_json` outbox | Zero change to existing pipeline |
| API | **API Gateway (REST, private) + Lambda** `/ask`, `/ask/stream`, `/health` | Standard, authorizable, throttleable |
| Agent (Opt 3) | **Amazon Bedrock Agents** with Action Groups = approved tool Lambdas | Managed orchestration; no raw SQL |
| Guardrails | **Amazon Bedrock Guardrails** (denied topics, PII, grounding) | Federal safety posture |
| IaC | **Terraform**, modular, per-env (`dev` first) | Team standard; reproducible; destroyable |
| Networking | All in **VPC**; AOSS + Lambda via **VPC endpoints**; API GW **private** | No public data plane |
| Secrets | **AWS Secrets Manager** / SSM Parameter Store | No creds in code |
| Region | Match existing SPARKS region (confirm) | Data residency |

---

## 1. End-to-end architecture (prod)

```
                         (FED-approved, Dev first)
EventBridge (rate) ──► Extractor Lambda (read-only)
                           │  SELECT osj_id, osj_table_index_name, osj_json_data
                           ▼
                     S3 curated search content (SSE-KMS, versioned)   ◄── DLQ on failure
                           │  (manifest per run)
                           ▼
                 Bedrock Knowledge Base  ──embed(Titan)──►  OpenSearch Serverless (vector)
                           ▲                                        │
User ─► API GW (private) ─► Ask Lambda ─► [Option 1] KB Retrieve ──┘
          │  authZ (IAM/Okta)      │        └► Claude (Bedrock) ─► grounded answer + citations(uniqueId)
          │                        │
          │                        └► [Option 2] Bedrock Agent
          │                               ├─ tool: semanticSearch  → KB/AOSS
          │                               ├─ tool: openSearchSearch → EXISTING sparks-stage
          │                               ├─ tool: getInvestigation/getVehicle/getEquipment → read-only RDS views
          │                               └─ Guardrails + merge-by-uniqueId
          ▼
   Ask SPARKS chat box (existing UI)  ◄─ answer + citations deep-link to records by uniqueId
```

**Observability spine (all steps):** CloudWatch Logs + Metrics + X-Ray traces; cost + token metrics per request; Bedrock model-invocation logging to S3.

---

## 2. Data refresh & consistency (prod-grade)

- **Trigger:** EventBridge schedule (default **every 15 min** in prod; configurable). Decoupled from the existing 5-min OpenSearch cycle.
- **Incremental:** extractor selects rows where `osj_update_dt > last_run_watermark` (watermark in SSM); re-embeds only changed `uniqueId`s. Full rebuild is an on-demand job.
- **Idempotent:** S3 object key = `uniqueId`; overwrite-on-change; S3 versioning retains history.
- **KB sync:** Knowledge Base ingestion job runs after each search content write (event-driven via S3 → EventBridge → StartIngestionJob).
- **Failure handling:** extractor failures → DLQ (SQS) + CloudWatch alarm; partial runs resume from watermark.
- **Freshness SLO:** a changed SPARKS record is query-answerable within **≤ 20 min** (15-min schedule + ingestion). Tune per FED.
- **Backfill:** one-time full embed job sized from `SELECT count(*)` per index (see cost doc).

---

## 3. API specification (prod)

### `POST /ask` (Option 1 default; Option 2 if `mode=agent`)
Request:
```json
{ "query": "child seats that failed labeling under FMVSS 213 since 2020",
  "filters": { "fmvss_code": "213", "compliance_prg_yr_gte": 2020 },
  "top_k": 8, "mode": "rag" }
```
Response:
```json
{ "request_id": "uuid",
  "answer": "…grounded summary…",
  "citations": [ { "uniqueId": "legacy_equipment:12251", "brand": "Evenflo",
                   "test_results": "Fail", "snippet": "…", "score": 0.82 } ],
  "followups": ["Compare to 2008 program results"],
  "usage": { "input_tokens": 4123, "output_tokens": 512, "tool_calls": 0 },
  "latency_ms": 1840, "mode": "rag" }
```
Contract rules: every answer sentence maps to ≥1 citation; empty-retrieval → "no grounded answer found" (never hallucinate); `request_id` on every response for trace correlation.

### `POST /ask/stream`  — Server-Sent Events for token streaming (chat UX).
### `GET /health` — liveness + KB/AOSS reachability (no auth).

**AuthN/Z:** API GW private + IAM; map SPARKS user identity (Okta — note the linked SB-6561 Okta story) to a least-privilege role. **Throttling:** per-user + global rate limits; WAF on the edge.

---

## 4. Option 2 — agent tools as Bedrock Action Groups

| Tool (OpenAPI action) | Backing Lambda | Data source | Access |
|---|---|---|---|
| `semanticSearch(query, filters, top_k)` | `tool-semantic` | KB / AOSS vector | read-only |
| `openSearchSearch(query, filters)` | `tool-keyword` | **existing** sparks-stage | read-only |
| `getInvestigation(uniqueId)` | `tool-get` | RDS **read-only view** | read-only |
| `getVehicle(uniqueId)` / `getEquipment(uniqueId)` | `tool-get` | RDS **read-only view** | read-only |

- Each tool has a strict JSON schema (OpenAPI 3) registered as a Bedrock **Action Group**.
- Agent merges/dedupes results by `uniqueId`; max N tool calls per session (loop cap) to bound cost.
- **No raw SQL tool, ever.** Lambdas use parameterized queries against read-only views/roles.

---

## 5. Security & compliance (federal posture)

- **Least privilege IAM** per Lambda: extractor can only `SELECT` the outbox view; `tool-get` only the read-only views; Ask Lambda can only invoke the specific Bedrock model + KB.
- **Encryption:** S3 + AOSS + logs with **KMS CMK**; TLS in transit; no public endpoints.
- **No PII in prompts beyond approved fields;** Bedrock Guardrails for denied topics + PII redaction; prompt-injection mitigations on tool inputs.
- **Audit:** CloudTrail on Bedrock/S3/AOSS; model-invocation logging; every answer stored with `request_id`, cited `uniqueId`s, token counts (the `AnswerCitation` / `AgentToolCall` entities in the proposed ER).
- **Data residency:** single approved region; search content is a derived read-only copy of already-indexed data.
- **Tenancy:** AI vector store is a **separate AOSS collection**, not the production search domain.

---

## 6. Observability & SLOs

| Signal | Mechanism | Target (Dev → Prod) |
|---|---|---|
| Latency (RAG) | X-Ray + CW metric | p95 < 3s |
| Latency (Agent) | X-Ray spans per tool | p95 < 8s |
| Groundedness | eval harness + sampled LLM-judge | ≥ agreed threshold |
| Citation correctness | eval harness vs golden set | 100% answers cite ≥1 uniqueId |
| Cost / tokens | per-request `usage` → CW metric + budget alarm | within monthly cap |
| Freshness | watermark lag metric | ≤ 20 min |
| Errors / DLQ depth | CW alarms | 0 sustained |

Dashboards: one CloudWatch dashboard per env (latency, tokens, cost, freshness, errors). **AWS Budgets** alarm at 50/80/100% of the approved Dev cap → auto-notify + optional throttle.

---

## 7. Evaluation gate (must pass before prod promote)

- **Golden set** (`GoldenEvalItem`): ≥ N SME-authored Q&A with ground-truth `uniqueId`s per domain.
- **Metrics:** recall@k, citation correctness, groundedness, answer relevance, latency, cost/query.
- **Gate:** CI job runs the harness; promote Dev→Prod only if thresholds met (agreed with FED). Deterministic checks + LLM-judge + SME spot review.

---

## 8. CI/CD & environments

- **Envs:** `dev` (first), then `prod`. Terraform workspaces/dirs per env; remote state in S3 + DynamoDB lock.
- **Pipeline:** lint/validate (`terraform validate`, `tflint`, `checkov`) → plan (PR gate) → apply (approval) → deploy Lambdas → run eval harness → promote.
- **Lambda packaging:** versioned artifacts; blue/green aliases; rollback = shift alias.
- **Change safety:** nothing in the existing SPARKS pipeline is modified by any pipeline here.

---

## 9. Cost controls (prod)

- Re-embed only changed docs (watermark); cap `top_k`, context length, agent loop count.
- Haiku-class model for intent/classify/followups; Sonnet-class only for the final grounded answer.
- AOSS right-sized (min OCUs in Dev); scale on measured load.
- AWS Budgets + per-request token metric; hard monthly cap in Dev.

---

## 10. Rollback & DR

- **Feature flag** on the "Ask SPARKS" chat box → instant disable (UI falls back to existing search; zero impact since structured search is untouched).
- **Lambda alias rollback** for bad deploys.
- **Search-content/vector rebuild** from S3 versioned objects (replay) if the index is corrupted.
- **No data-loss risk** to SPARKS: the AI layer is 100% derived and read-only.

---

## 11. Go-live runbook (sequence)

1. FED Lead approval recorded → provision **Dev** via Terraform (`infra/terraform/envs/dev`).
2. Backfill embed job (sized from counts); verify KB ingestion.
3. Point `/ask` at Dev; smoke test `/health`.
4. Run eval harness; review with SME; confirm thresholds.
5. Enable chat box behind feature flag for pilot users.
6. Monitor dashboards + budget for the pilot window.
7. Decision gate → promote to Prod (same Terraform, `prod` env) or iterate.

---

## 12. Confir--before-apply checklist (the only remaining unknowns)

- [ ] AWS region + VPC/subnets/SG for the AI stack
- [ ] Bedrock model IDs enabled in the account (Claude + Titan Embeddings)
- [ ] `SELECT count(*)` per index → backfill sizing
- [ ] Okta → IAM identity mapping for `/ask` (ties to SB-6561)
- [ ] Read-only RDS view names for `getInvestigation/getVehicle/getEquipment`
- [ ] FED thresholds for the eval gate + monthly Dev cost cap
- [ ] FE contract for the chat box (request/response, streaming, citation click-through)
