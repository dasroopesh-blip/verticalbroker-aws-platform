# SPARKS Current OpenSearch Indexing — As-Is (grounded in actual code)

This is the existing pipeline. **Nothing here changes** in Option 1 or Option 2.
The names, batch sizes, and flags below are taken directly from the Lambda handlers
and the `sparks.pushjsondata` / `sparks.pushindextoopensearchtable` PL/pgSQL functions.

```mermaid
flowchart LR
    SCHED["Amazon EventBridge<br/>Scheduler<br/>(rate: 5 min)"]

    subgraph PG["SPARKS PostgreSQL / RDS"]
        BUILDERS["Domain JSON builders<br/>json_vtf_rec()<br/>json_etf_rec()<br/>json_etfi_rec()<br/>json_gi_rec()<br/>json_vtfi_rec()<br/>json_legacy_vehicle_rec()<br/>json_legacy_equipment_rec()<br/>json_legacy_investigation_rec()"]
        PUSHIDX["pushIndexToOpenSearchTable()<br/>calls pushJsonData() per index"]
        OUTBOX["sparks.open_search_json (outbox)<br/>osj_id · osj_table_index_name<br/>osj_json_data · osj_read_yn<br/>osj_processed_yn · osj_update_dt"]
        BUILDERS --> PUSHIDX --> OUTBOX
    end

    subgraph L1["RDS-to-SQS Lambda"]
        L1A["1. SELECT sparks.pushIndexToOpenSearchTable()<br/>2. SELECT * WHERE osj_read_yn=false<br/>   AND index IN (5 core + 3 legacy)<br/>   ORDER BY osj_create_dt DESC LIMIT 50<br/>3. Batch of 10 -> SendMessageBatchCommand<br/>4. On success: UPDATE osj_read_yn=true"]
    end

    subgraph SQS["SearchQueue.fifo"]
        Q["FIFO queue<br/>MessageGroupId = index name<br/>MessageDeduplicationId = osj_id<br/>Attributes: DatabaseId(osj_id), IndexName<br/>(IDs only — not the full payload)"]
    end

    subgraph L2["SQS-to-OpenSearch Lambda"]
        L2A["1. checkIndex() -> createIndex() if missing<br/>   (never deletes existing docs)<br/>2. SELECT osj_json_data WHERE osj_id=DatabaseId<br/>3. Chunk 1000, stamp _id via _stableId()<br/>   legacy -> 'legacy_equipment:&lt;id&gt;' etc.<br/>   non-legacy -> uniqueId ?? id<br/>4. populateIndex() bulk<br/>5. UPDATE osj_processed_yn=true"]
    end

    subgraph OS["Amazon OpenSearch (sparks-stage)"]
        IDX["Indexes:<br/>general_inv · equip_test_file<br/>equip_test_failure_inv<br/>vehicle_test_failure_inv · vehicle_test_file<br/>legacy_vehicle · legacy_equipment<br/>legacy_investigation"]
    end

    UI["SPARKS Search UI<br/>pills / filters / keyword search"]

    SCHED --> L1
    PUSHIDX -. "refreshes outbox" .-> OUTBOX
    L1 -->|read rows| OUTBOX
    L1 -->|"osj_id + index"| SQS
    SQS --> L2
    L2 -->|"re-fetch by osj_id"| OUTBOX
    L2 -->|bulk index| OS
    OS --> UI
```

## Row lifecycle (from `pushJsonData` + both Lambdas)

```mermaid
stateDiagram-v2
    [*] --> New: builder output written<br/>read=N, processed=N
    New --> Queued: RDS-to-SQS sends to FIFO<br/>sets read=Y
    Queued --> Indexed: SQS-to-OpenSearch bulk-indexes<br/>sets processed=Y
    Indexed --> [*]
    Queued --> New: pushJsonData reset<br/>read=Y, processed=N, update_dt > 15 min ago<br/>(hung-record recovery)
    note right of New
        pushJsonData also:
        - updates in place if an unprocessed
          row exists for the index
        - skips exact-duplicate JSON
        - inserts only when no row exists yet
    end note
```

## Notes that matter for the AI design
- `osj_json_data` is a **denormalized document array** — already the right shape for AI retrieval / search content.
- Every doc carries `uniqueId` (e.g. `legacy_equipment:12251`); the consumer stamps the OpenSearch `_id` from it. This is a ready-made citation key.
- The outbox (`sparks.open_search_json`) is the natural, read-only tap point for AI search content — no operational tables are touched.
