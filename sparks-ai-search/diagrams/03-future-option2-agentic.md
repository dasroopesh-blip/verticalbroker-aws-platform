# Option 2 — Agentic Hybrid Search (Future / To-Be)

Everything in Option 1, plus an agent that decides **which approved tool** to call.
Crucially, the agent's "keyword/filter" tool is the **existing OpenSearch index** —
the current pipeline is reused as one tool, not rebuilt.

```mermaid
flowchart TB
    ASK["Ask SPARKS (Agentic)<br/>'Find Ford investigations since 2022 involving<br/>camera/visibility failures, compare them, and<br/>tell me which resulted in recalls.'"]

    subgraph AGENT["Agent Orchestration (Bedrock Agent / AgentCore)"]
        PLAN["Claude plans the steps<br/>interpret intent · pick tools ·<br/>combine results · ground the answer"]
        subgraph TOOLS["Approved tool set"]
            T1["openSearchSearch()<br/>EXISTING index — exact/filter"]
            T2["semanticSearch()<br/>vector retrieval (Option 1 search content)"]
            T3["getInvestigation() / getVehicle()<br/>getEquipment() — read-only lookups by uniqueId"]
            T4["(optional) reference docs,<br/>procedures, approved APIs"]
        end
        PLAN --> TOOLS
    end

    subgraph SOURCES["Data sources"]
        OS2["EXISTING OpenSearch<br/>(unchanged pipeline)"]
        subgraph AICORP["AI search content (same as Option 1)"]
            S3b["S3 curated docs"]
            KBb["Bedrock KB"]
            VECb["Vector index"]
            S3b --> KBb --> VECb
        end
        EXTRA["Other approved sources<br/>RDS read-only views · reference material"]
    end

    RESP["Grounded answer with sources<br/>'12 investigations since 2022…'<br/>related IDs (uniqueId) · key insights ·<br/>follow-up suggestions"]

    ASK --> AGENT
    T1 --> OS2
    T2 --> VECb
    T3 --> EXTRA
    AGENT --> RESP

    style OS2 fill:#eee,stroke:#999
```

### Option 1 vs Option 2 in one line
- **Option 1 (RAG):** we enrich the search content *ahead of time*; Claude answers from retrieval.
- **Option 2 (Agentic):** the agent can *also* call approved live tools (incl. the current
  OpenSearch) when the search content doesn't fully cover the question — multi-step reasoning.
