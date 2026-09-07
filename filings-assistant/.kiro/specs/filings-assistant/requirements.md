# Requirements: Filings Assistant

## Introduction

An Agentic RAG assistant that ingests public SEC EDGAR filings and answers
natural-language questions with grounded, cited responses. It exposes its
capabilities as MCP tools and uses Amazon Bedrock (Claude Sonnet for reasoning,
Titan V2 for embeddings) with Amazon OpenSearch for hybrid retrieval.

## Requirements

### R1 — Ingest public filings
**User story:** As an analyst, I want to ingest a company's SEC filing so it
becomes searchable.
- WHEN a user requests ingest by ticker + form, the system SHALL fetch the
  filing(s) from SEC EDGAR (with a compliant User-Agent).
- The system SHALL store each filing's raw text + metadata in a source-of-truth
  database with a content checksum.
- IF a filing with the same checksum already exists, the system SHALL NOT
  duplicate it (idempotent).
- After storing, the system SHALL enqueue the filing for asynchronous indexing.

### R2 — Index for hybrid search
- The worker SHALL chunk filing text into overlapping windows.
- The worker SHALL embed each chunk via Bedrock Titan and index text + vector
  into OpenSearch using a k-NN vector mapping.
- On repeated failure, messages SHALL route to a dead-letter queue.
- Filing status SHALL transition PENDING → INDEXING → INDEXED / FAILED.

### R3 — Search
- The system SHALL support keyword (BM25), semantic (k-NN), and hybrid search.
- Hybrid search SHALL fuse keyword + semantic results via Reciprocal Rank Fusion.
- Every result SHALL carry a citation and source URL.

### R4 — MCP tools
- The system SHALL expose `ingest_filing`, `keyword_search`, `semantic_search`,
  `hybrid_search`, `get_document`, and `list_filings` as MCP tools.
- The MCP tools and the in-process agent SHALL share one implementation.

### R5 — Agentic answering
- The agent SHALL plan, call retrieval tools, and synthesize a cited answer.
- The agent SHALL ground claims in retrieved text and state when the answer is
  not present in the filings.
- The agent SHALL NOT provide investment advice.
- The reasoning loop SHALL be bounded (always terminates).

### R6 — Run locally at $0
- The system SHALL run fully offline using in-memory stores and a mock Bedrock
  client, selectable by configuration.
- The same code SHALL run on AWS by changing environment variables only.

### R7 — Deployable infrastructure
- Terraform SHALL provision VPC, OpenSearch, RDS Postgres, SQS (+ DLQ), the
  worker Lambda, least-privilege IAM (Bedrock scoped to specific model ARNs),
  KMS encryption, and a cost budget alarm.
- Terraform SHALL be organized into commented, single-concern modules.

### R8 — Cost safety
- Dev defaults SHALL use the smallest viable instances.
- A budget alarm SHALL notify at 50% and 90% of a configurable monthly budget.
- Teardown SHALL be a single documented command.
```
