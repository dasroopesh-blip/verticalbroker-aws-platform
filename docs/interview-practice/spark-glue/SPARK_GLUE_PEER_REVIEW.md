# Peer Review: Spark/Glue ETL Pipeline (Bronze/Silver/Gold)

**Reviewer:** Senior Data Engineer  
**Author:** Junior Developer  
**Status:** ❌ REQUEST CHANGES — Data loss, duplicate records, precision errors  
**Risk Level:** CRITICAL — Financial data pipeline with 25 errors

---

## Architecture Comparison

### Junior's Design (WRONG):
```
One Glue Job → Reads raw → writes Bronze → reads Bronze →
writes Silver → reads Silver → writes Gold → Done
```

Problems: Monolithic, not idempotent, cascading failures, can't restart from middle.

### Senior's Design (CORRECT):
```
┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
│ S3 Raw   │────▶│  BRONZE  │────▶│  SILVER  │────▶│   GOLD   │
│ (JSON)   │     │ Glue Job │     │ Glue Job │     │ Glue Job │
└──────────┘     └────┬─────┘     └────┬─────┘     └────┬─────┘
                      │                 │                 │
                      ▼                 ▼                 ▼
                 S3 Parquet        S3 Parquet        S3 Parquet
                (partitioned)     (partitioned)     (partitioned)
                      │                 │                 │
                      ▼                 ▼                 ▼
                 Glue Catalog      Glue Catalog      Glue Catalog
                (bronze DB)        (silver DB)       (gold DB)
                      │
                      ▼
                 Dead Letter
                 (bad records)

Orchestrated by: Step Functions (Bronze → Silver → Gold)
Scheduled by: EventBridge (daily cron)
Monitored by: CloudWatch Alarms + SNS
```

---

## 25 Errors Found in Junior's PySpark Code

### 🔴 P0 — Data Loss / Incorrect Financial Data

| # | Error | Line(s) | Impact | Fix |
|---|-------|---------|--------|-----|
| 1 | No schema enforcement | `spark.read.json(INPUT_PATH)` | Schema drift causes silent wrong results. Quantity could be inferred as String one day. | Define `StructType` with `DecimalType(12,4)` for price |
| 2 | Float arithmetic for money | `F.col("quantity") * F.col("price")` | DoubleType multiplication → precision loss. 0.1 * 3 ≠ 0.30 | Cast to `DecimalType` before multiplication |
| 3 | `mode("append")` on Bronze | `df.write.mode("append").parquet(BRONZE_PATH)` | Job rerun = DUPLICATE records in Bronze, propagating to Silver & Gold | `mode("overwrite")` on partition (idempotent) |
| 4 | `mode("overwrite")` on ENTIRE Silver | `silver_df.write.mode("overwrite").parquet(SILVER_PATH)` | Overwrites ALL historical Silver data! Only today survives! | `mode("overwrite")` with `.partitionBy("trade_date")` |
| 5 | No deduplication | No `dropDuplicates` anywhere | Duplicate SQS deliveries → duplicate records → customer charged twice in reports | `dropDuplicates(["request_id"])` |
| 6 | No validation/quality gates | No checks on data | 90% garbage data writes to Gold → executives see wrong numbers | Validation rules + quality gate (fail if >5% errors) |
| 7 | No dead letter handling | No separation of bad records | Malformed records either crash job or corrupt downstream | Write invalid records to separate dead letter path |

### 🟠 P1 — Reliability / Performance / Operational

| # | Error | Impact | Fix |
|---|-------|--------|-----|
| 8 | Hardcoded paths | Can't run for different dates, can't backfill, no environment isolation | Pass as Glue job parameters |
| 9 | Hardcoded date | Can't process yesterday or backfill historical data | `--run_date` parameter |
| 10 | `.count()` before processing | Triggers expensive full scan just for a print | Remove or defer to after cache |
| 11 | Reads ALL Bronze (not partition) | Reads years of history when only today's data needed | Read specific partition path |
| 12 | No partitioning on write | Every Athena query = full table scan ($$$, slow) | `.partitionBy("trade_date", "symbol")` |
| 13 | `repartition(1)` on Gold | All data through one executor → OOM, killed parallelism | `repartition("trade_date")` or AQE |
| 14 | `.show(1000)` in production | Triggers extra computation, outputs business-sensitive data | Remove entirely |
| 15 | `.collect()` on millions of rows | Pulls all data to driver memory → OOM crash | Never collect large DataFrames |
| 16 | No `job.commit()` | Glue bookmarks never update → reprocesses same files | Always call `job.commit()` |
| 17 | No job bookmarks in Terraform | Same effect as #16 from infrastructure side | `--job-bookmark-option = "job-bookmark-enable"` |
| 18 | All layers in one job | Bronze/Silver/Gold failure cascades; can't restart from middle | Separate Glue jobs + Step Functions |
| 19 | Default shuffle partitions (200) | Way too many for typical data volumes → tiny files, slow reads | Set to 30-50 based on data size |
| 20 | No CloudWatch metrics | Can't alert on job duration, data quality, record counts | `--enable-metrics`, custom metrics |

### 🟡 P2 — Maintainability

| # | Error | Impact | Fix |
|---|-------|--------|-----|
| 21 | No metadata columns | Can't trace data lineage (when ingested, from where) | Add `_ingestion_timestamp`, `_source_file`, `_job_run_id` |
| 22 | Only one Gold aggregation | Missing customer activity, exchange volume, hourly patterns | Multiple Gold tables for different use cases |
| 23 | No Glue Catalog integration | Data not discoverable via Athena/QuickSight | `.saveAsTable()` to register in Glue Catalog |
| 24 | No error handling | Job crashes with cryptic Spark stacktrace | try/except with meaningful error messages |
| 25 | `spark.stop()` in Glue job | Glue manages SparkContext lifecycle | Remove — let Glue handle it |

---

## Terraform Errors (Junior's `terraform_junior_glue.tf`)

| # | Error | Severity | Impact | Fix |
|---|-------|----------|--------|-----|
| 1 | No terraform block/backend | P1 | Local state, no locking, no versioning | S3 backend + DynamoDB lock |
| 2 | Single bucket for all layers | P1 | Can't set different permissions per layer | Separate buckets per tier |
| 3 | No S3 encryption | P0 | Financial data unencrypted at rest | KMS encryption on all buckets |
| 4 | No public access block | P0 | Financial reports could be made public | Block all public access |
| 5 | No lifecycle rules | P2 | Storage costs grow unbounded | IA → Glacier → Expire |
| 6 | Single Glue database | P2 | Bronze/Silver/Gold all mixed together | Separate databases per layer |
| 7 | One monolithic job | P1 | Can't restart from middle, cascading failures | Three separate jobs |
| 8 | Only 2 DPU | P1 | Extremely slow on production volumes | G.2X workers, 5-10 per job |
| 9 | No timeout | P2 | Job could run forever ($$$) | `timeout = 60` (minutes) |
| 10 | No Glue version | P1 | Uses deprecated default | `glue_version = "4.0"` |
| 11 | No worker type | P2 | G.1X default is too small | `worker_type = "G.2X"` |
| 12 | No parameters | P1 | Can't parameterize for dates/environments | `default_arguments` block |
| 13 | No bookmarks | P1 | Reprocesses same files every run | `--job-bookmark-option` |
| 14 | `AdministratorAccess` IAM | **P0** | Glue can delete ANY resource in account | Least-privilege per-bucket |
| 15 | No orchestration | P1 | Must start manually, no dependency ordering | Step Functions + EventBridge |
| 16 | No monitoring | P1 | Failures go unnoticed until users complain | CloudWatch alarms + SNS |
| 17 | No tags | P2 | Can't track costs or ownership | Common tags on all resources |

---

## Layer Comparison: Junior vs Senior

| Aspect | Junior | Senior |
|--------|--------|--------|
| **Bronze** | Raw dump, no schema, no validation | Schema enforced, metadata added, corrupt → dead letter |
| **Silver** | Float math, no dedup, overwrites all history | DecimalType, deduplicated, partition-level overwrite |
| **Gold** | Single aggregation, repartition(1) | 4 Gold tables, proper partitioning, VWAP calculation |
| **Idempotency** | append (duplicates) or overwrite (data loss) | Partition-level overwrite (safe re-runs) |
| **Quality** | None | Quality gates at every layer (5-10% threshold) |
| **Dead Letter** | Missing entirely | Separate path per layer with rejection reasons |
| **Catalog** | Not registered | All tables in Glue Catalog (Athena-queryable) |
| **Orchestration** | Manual | Step Functions: Bronze → Silver → Gold with error routing |
| **Monitoring** | print() statements | CloudWatch metrics + alarms + SNS alerts |

---
