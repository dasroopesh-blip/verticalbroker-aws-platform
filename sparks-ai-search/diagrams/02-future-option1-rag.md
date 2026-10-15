# Option 1 — RAG / "Ask SPARKS" (Future / To-Be)

Keeps the **entire current pipeline unchanged** (greyed box). Adds a separate,
read-only AI path that taps the **same `sparks.open_search_json` outbox** the
current consumer already reads — so the AI search content reuses the exact
denormalized documents (and their `uniqueId` citation keys) that OpenSearch
indexes today.

```mermaid
flowchart TB
    subgraph CURRENT["EXISTING PIPELINE — UNCHANGED"]
        direction LR
        PG1["SPARKS PostgreSQL<br/>+ JSON builders"]
        OB1["sparks.open_search_json<br/>(outbox)"]
        RL["RDS-to-SQS Lambda"]
        FQ["SearchQueue.fifo"]
        OL["SQS-to-OpenSearch Lambda"]
        OS1["OpenSearch (sparks-stage)"]
        PG1 --> OB1 --> RL --> FQ --> OL --> OS1
    end

    subgraph AIPREP["AI Data Preparation (NEW, read-only)"]
        EXTRACT["Scheduled extractor<br/>(Lambda / Glue)<br/>reads osj_json_data read-only"]
        ENRICH["Enrich (optional):<br/>+ failure_type / prob_summary / sme_recc<br/>+ related comments, status history<br/>+ reference-table values"]
        S3["S3 curated AI search content<br/>partitioned by domain<br/>(investigation / vehicle / equipment /<br/>test-failure / legacy)"]
        EXTRACT --> ENRICH --> S3
    end

    subgraph RETRIEVE["AI Retrieval Layer (Amazon Bedrock)"]
        KB["Bedrock Knowledge Base<br/>chunk + embed + store"]
        VEC["Vector index<br/>OpenSearch vector index<br/>(same domain — lowest friction)"]
        CLAUDE["Claude (Bedrock)<br/>grounded answer + citations<br/>citations reuse uniqueId<br/>e.g. legacy_equipment:12251"]
        KB --> VEC --> CLAUDE
    end

    ASK["Ask SPARKS (same search UI)<br/>natural-language Q&A · summaries<br/>similar cases · follow-ups<br/>source links via uniqueId"]

    OB1 -. "read-only tap<br/>(no change to outbox)" .-> EXTRACT
    S3 --> KB
    CLAUDE --> ASK
    OS1 -. "existing keyword/filter search<br/>stays available" .-> ASK

    style CURRENT fill:#eee,stroke:#999
```

### Why this answers "why two searches?"
One UI, two retrieval capabilities. Exact/filtered lookups keep using the current
OpenSearch index; natural-language/semantic requests use the RAG path. The AI path
**reads the same outbox** rather than duplicating or modifying the operational search,
so there is no second user-facing search and no change to the indexing pipeline.
