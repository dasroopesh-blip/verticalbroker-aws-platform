# Design decisions & rationale

This records the "why" behind the main choices, so future changes are informed.

## Why this project

Financial analysts need to answer questions across large filings quickly, with
**auditable, cited** answers. Generic LLM chat hallucinates numbers — unacceptable
in a regulated context. Retrieval-Augmented Generation (RAG) grounds answers in
the actual filing text; the agentic layer lets the model *decide* what to
retrieve and how to combine it.

## Decision table

| Decision | Choice | Rationale |
|---|---|---|
| Reasoning LLM | **Claude Sonnet** (Bedrock) | Strong tool-use + multi-step reasoning at reasonable cost; ideal for agents. Opus is overkill/costlier for RAG. |
| Embeddings | **Titan Text Embeddings V2** (Bedrock) | Cheap, native to Bedrock, good quality. Cohere is a drop-in alternative for multilingual. |
| LLM platform | **Bedrock**, not SageMaker | No custom model to train; we consume foundation models. Bedrock is pay-per-token and scales to zero. SageMaker left as a future seam for a fine-tuned reranker. |
| Vector + text store | **Amazon OpenSearch** | One system does both k-NN vector AND BM25 keyword search → hybrid retrieval, and satisfies the "search product" goal. |
| Retrieval fusion | **Reciprocal Rank Fusion** | Combines rankings, not raw scores (BM25 and cosine are on different scales); robust and parameter-light. |
| Source of truth | **Postgres (RDS)** | OpenSearch is a rebuildable index; Postgres is the durable record enabling re-index after model/mapping changes. Supports audit/lineage. |
| Decoupling | **SQS (+ DLQ)** | Ingestion is slow/bursty; the queue keeps the write path fast and gives retries + poison-message quarantine. |
| Compute | **Lambda** worker | Event-driven, scales to zero, cheapest for bursty indexing. |
| IaC | **Terraform** | Requested for learning; industry-standard, mature, cloud-portable. Written module-per-concern with heavy comments. |
| Tool interface | **MCP** | Exposes capabilities as standard tools so the agent AND external clients (Claude Desktop, IDEs) share identical behavior. |
| Local parity | **Config-selected fakes** | Same code runs offline ($0) or on AWS; no business-logic branching. |

## Financial-domain guardrails

- **No investment advice.** The agent system prompt forbids buy/sell/hold
  recommendations; it reports what filings disclose. This is a compliance-minded
  default for FSI contexts.
- **Citations everywhere.** Every retrieved passage carries a citation
  (`TICKER FORM (date), Item`) surfaced in tool results and the final answer.
- **Data lineage.** Postgres stores source URL, accession number, checksum,
  timestamps, and ingest status per filing — an audit trail.
- **Least-privilege IAM.** The worker can invoke only the two specific Bedrock
  model ARNs, consume only its SQS queue, and use only its KMS key.

## Cost strategy

Tokens are cheap; idle infra is not. Mitigations:
- Local-first development ($0).
- Smallest dev instances by default (documented as "bump for prod").
- No NAT Gateway in the dev VPC (~$32/mo saved).
- `terraform destroy` teardown documented prominently.
- AWS Budgets alarm at 50% / 90%.

## Known limitations / future work

- **HTML→text** extraction is intentionally light; a production system would use
  a robust filing parser and section splitter (e.g. per-Item structure).
- **Chunking** approximates tokens as words; swap in a real tokenizer for tighter
  size control.
- **Reranker seam** — a SageMaker cross-encoder reranker could re-order the fused
  candidates for higher precision (left as a future module).
- **Agent long-running host** — the agent currently runs via CLI/MCP; a Fargate
  service could expose it as an always-on API (module can be added).
- **Evaluation** — add a retrieval/answer eval harness (golden Q&A over known
  filings) before trusting production answers.
