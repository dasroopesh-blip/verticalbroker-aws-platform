# Interview Q&A Practice: Spark / Glue / Bronze-Silver-Gold

---

## Q1: Explain the Bronze/Silver/Gold medallion architecture. Why separate layers?

**Senior Answer:**

"The medallion architecture organizes a data lakehouse into three quality tiers:

**Bronze (Raw/Landing):**
- Data exactly as received, minimal transformation
- Add metadata: ingestion timestamp, source file, job ID
- Purpose: immutable audit trail, always be able to reprocess from source
- Schema: permissive (accept everything, flag corrupt records)

**Silver (Cleansed/Conformed):**
- Validated, deduplicated, properly typed
- Business rules applied (valid symbols, positive quantities)
- Decimal types for financial data (no floats)
- Purpose: single source of truth, ready for business logic

**Gold (Business/Aggregated):**
- Pre-computed metrics, KPIs, dimensional models
- Optimized for specific consumers (dashboards, reports, ML)
- Purpose: fast queries, no heavy computation at read time

**Why separate?**
1. **Failure isolation** — If Gold fails, Bronze and Silver are untouched
2. **Reprocessing** — Can rerun Silver from Bronze without re-ingesting
3. **Different SLAs** — Bronze: minutes, Silver: hours, Gold: daily
4. **Access control** — Data engineers see Bronze, analysts see Gold
5. **Cost optimization** — Gold is small (aggregated), hot storage; Bronze is big, cold storage"

---

## Q2: Why is `df.write.mode("append").parquet(BRONZE_PATH)` dangerous?

**Senior Answer:**

"It's not idempotent. If the job fails halfway and Glue retries it:

**First run (fails at Silver stage):**
- Bronze: writes 10,000 records ✓
- Silver: FAILS ✗
- Job marked as failed

**Second run (retry):**
- Bronze: writes SAME 10,000 records AGAIN (append!)
- Now Bronze has 20,000 records (10,000 are duplicates)
- Silver processes all 20,000 → duplicates propagate
- Gold aggregations show 2× the actual volume

**The fix: partition-level overwrite**
```python
df.write.mode('overwrite').partitionBy('_ingestion_date').parquet(BRONZE_PATH)
```

This overwrites ONLY today's partition. If the job reruns, it replaces today's data
with the same data — no duplicates, no data loss from other days.

Combined with Glue bookmarks (tracking which S3 files have been processed), this
gives us exactly-once semantics at the Bronze layer."

---

## Q3: Why does `silver_df.write.mode("overwrite").parquet(SILVER_PATH)` DELETE all historical data?

**Senior Answer:**

"Because `mode('overwrite')` WITHOUT `partitionBy` overwrites the ENTIRE directory.

**What the junior wrote:**
```python
silver_df.write.mode('overwrite').parquet(SILVER_PATH)
```

This means: 'Delete everything at SILVER_PATH, then write only today's data.'
Yesterday's Silver data? Gone. Last month's? Gone. All history = destroyed.

**What should have been written:**
```python
silver_df.write.mode('overwrite').partitionBy('trade_date', 'symbol').parquet(SILVER_PATH)
```

With `partitionBy`, Spark creates subdirectories:
```
silver/trade_date=2024-01-15/symbol=AAPL/part-00000.parquet
silver/trade_date=2024-01-15/symbol=MSFT/part-00000.parquet
silver/trade_date=2024-01-14/symbol=AAPL/...  ← UNTOUCHED
```

`mode('overwrite')` now only overwrites partitions that appear in today's data.
Historical partitions remain untouched.

This is why partition design is a DAY ONE decision in data engineering — get it wrong
and you either lose history or create duplicates."

---

## Q4: Why can't you use DoubleType (float) for financial calculations in Spark?

**Senior Answer:**

"Same issue as Python's `float` — IEEE 754 double-precision can't represent all
decimal fractions exactly.

**Spark demonstration:**
```python
df = spark.createDataFrame([(3, 0.1)], ['quantity', 'price'])
df.withColumn('total', F.col('quantity') * F.col('price')).show()
# +--------+-----+-------------------+
# |quantity|price|              total|
# +--------+-----+-------------------+
# |       3|  0.1|0.30000000000000004|
# +--------+-----+-------------------+
```

When you then SUM millions of trades:
```python
# 1 million trades at $0.10 each, quantity 1
# Expected: $100,000.00
# Actual with DoubleType: $100,000.00000000XXX (accumulated error)
# After rounding: might be $99,999.99 or $100,000.01
```

Over a day with 10 million trades, the cumulative error in Gold aggregations could be
hundreds or thousands of dollars — enough to fail financial reconciliation.

**The fix in Spark:**
```python
from pyspark.sql.types import DecimalType

# At read time — enforce schema:
StructField('price', DecimalType(12, 4), nullable=False)

# At computation time — explicit cast:
df.withColumn('total',
    (F.col('quantity').cast(DecimalType(12, 4)) * F.col('price'))
    .cast(DecimalType(18, 2))
)
```

`DecimalType(12, 4)` = 12 total digits, 4 after decimal point.
`DecimalType(18, 2)` = 18 total digits, 2 after decimal point (for totals).

Spark's Decimal uses Java's BigDecimal under the hood — arbitrary-precision, exact."

---

## Q5: Why is `repartition(1)` a performance killer?

**Senior Answer:**

"The junior wrote:
```python
agg_df.repartition(1).write.mode('overwrite').parquet(GOLD_PATH)
```

**What this does:**
1. ALL data from all executors shuffles to ONE single partition
2. Only ONE executor core processes the entire write
3. Creates ONE output file (potentially huge)

**Problems:**
- **Network bottleneck** — All executors send data to one node
- **Memory pressure** — One executor must hold entire dataset in memory
- **OOM crash** — If Gold has 1GB+ of aggregated data, single executor dies
- **No parallelism** — 99 executors sit idle while 1 does all the work
- **Slow reads downstream** — Athena can't parallelize reading a single file

**Visual:**
```
Before repartition(1):  [Executor1] [Executor2] [Executor3] [Executor4]
                          ↓ data      ↓ data      ↓ data      ↓ data

After repartition(1):   [Executor1] ← ALL DATA
                        [Executor2] idle
                        [Executor3] idle
                        [Executor4] idle
```

**The fix:**
```python
agg_df.repartition('trade_date').write.partitionBy('trade_date').parquet(GOLD_PATH)
```

This distributes data across executors BY date, each writes its own partition in
parallel. Downstream queries on a specific date only read that partition."

---

## Q6: What is a Glue Bookmark and why does the junior need it?

**Senior Answer:**

"A Glue Bookmark tracks which S3 objects (files) have already been processed by a
job. On the next run, Glue only reads NEW files.

**Without bookmarks (junior's code):**
- Run 1: Processes files A, B, C
- Run 2: Processes files A, B, C, D, E (re-reads A, B, C!)
- Result: A, B, C are processed TWICE → duplicates in Bronze

**With bookmarks (senior's code):**
- Run 1: Processes files A, B, C → bookmark saved
- Run 2: Starts from bookmark → processes only D, E (new files)
- Result: No duplicates, efficient processing

**How to enable:**

Terraform:
```hcl
default_arguments = {
  '--job-bookmark-option' = 'job-bookmark-enable'
}
```

Python:
```python
# Must use DynamicFrame (not DataFrame) for bookmarks to work:
raw_dyf = glueContext.create_dynamic_frame.from_options(
    connection_type='s3',
    connection_options={'paths': [SOURCE_PATH], 'recurse': True},
    format='json',
    transformation_ctx='raw_source',  # THIS is the bookmark key
)
```

**Critical:** The `transformation_ctx` parameter IS the bookmark identifier. Without
it, bookmarks don't track anything.

**And you MUST call `job.commit()` at the end** — that's what saves the bookmark state.
The junior never calls `job.commit()`, so even if bookmarks were enabled, they'd never
be persisted."

---

## Q7: Explain the difference between `mode("overwrite")` vs `mode("append")` and when to use each.

**Senior Answer:**

"| Mode | Behavior | Idempotent? | Use When |
|------|----------|-------------|----------|
| `overwrite` (no partition) | Deletes ENTIRE directory, writes new data | ✅ for full-refresh only | Replacing entire table (DANGEROUS for incremental) |
| `overwrite` + `partitionBy` | Deletes only affected PARTITIONS, writes new | ✅ Yes! | Incremental loads (overwrite today's partition only) |
| `append` | Adds files to existing directory | ❌ Never | NEVER in an idempotent pipeline |
| `ignore` | Does nothing if path exists | ❌ | Almost never useful |
| `errorIfExists` | Fails if path exists | ❌ | One-time loads |

**For our trade pipeline:**
- **Bronze:** `overwrite` + `partitionBy('_ingestion_date')` → safe re-runs
- **Silver:** `overwrite` + `partitionBy('trade_date', 'symbol')` → safe re-runs
- **Gold:** `overwrite` + `partitionBy('trade_date')` → safe re-runs

**NEVER use `append` in a production ETL** because:
1. If job fails and retries → duplicates
2. If job runs twice accidentally → duplicates
3. If data needs to be corrected → can't overwrite, only add more

The combination of `mode('overwrite')` + `partitionBy(...)` is the idempotent
sweet spot: you can safely rerun any job any number of times and always get the
correct result."

---

## Q8: The junior uses `.collect()`. When is this acceptable?

**Senior Answer:**

"Almost NEVER in a production ETL job.

**What `.collect()` does:**
```python
all_results = agg_df.collect()  # Pulls ALL rows to driver memory
```

The driver is a single JVM with limited memory (typically 1-4 GB). If the DataFrame
has millions of rows, the driver runs out of memory and the job crashes with:
```
java.lang.OutOfMemoryError: Java heap space
```

**When it's acceptable:**
1. After a `.count()` → you know the result is exactly 1 row
2. After a heavy aggregation that guarantees tiny output (< 1000 rows)
3. For configuration data (small lookup tables)
4. In test/development on sampled data

**Better alternatives:**
```python
# Instead of: agg_df.collect()
# Use:
agg_df.write.parquet(OUTPUT)  # Write to S3 (distributed)

# If you need to inspect:
agg_df.show(10)  # Shows 10 rows (small)
agg_df.limit(10).toPandas()  # Converts 10 rows safely
```

**In the junior's code:**
```python
all_results = agg_df.collect()  # On production: millions of rows → OOM → job crashes
print(f'Results: {all_results}')  # Also prints financial data to logs!
```

This is a double failure: OOM crash + sensitive data in logs."

---

## Q9: Why does the senior use `for_each` in Terraform for S3 buckets?

**Senior Answer:**

"The senior has 6 S3 buckets (raw, bronze, silver, gold, dead_letter, scripts) that
all need the same configuration: versioning, encryption, public access block.

**Without `for_each` (junior approach):**
```hcl
# 6 buckets × 4 resources each = 24 resource blocks!
resource 'aws_s3_bucket' 'raw' { ... }
resource 'aws_s3_bucket_versioning' 'raw' { ... }
resource 'aws_s3_bucket_server_side_encryption_configuration' 'raw' { ... }
resource 'aws_s3_bucket_public_access_block' 'raw' { ... }
# Repeat 5 more times...
```

**With `for_each` (senior approach):**
```hcl
locals {
  data_buckets = {
    raw         = { name = '...', data_tier = 'landing' }
    bronze      = { name = '...', data_tier = 'bronze' }
    silver      = { name = '...', data_tier = 'silver' }
    gold        = { name = '...', data_tier = 'gold' }
    dead_letter = { name = '...', data_tier = 'error' }
    scripts     = { name = '...', data_tier = 'infrastructure' }
  }
}

resource 'aws_s3_bucket' 'data_lake' {
  for_each = local.data_buckets
  bucket   = each.value.name
}
```

**Benefits:**
1. **DRY** — Define bucket config once, apply to all
2. **Consistency** — Impossible to forget encryption on one bucket
3. **Maintainability** — Add a new bucket = add one entry to the map
4. **Readable** — All bucket configurations in one place
5. **Stable addressing** — `aws_s3_bucket.data_lake['bronze']` is clear"

---

## Q10: Why does the senior use Step Functions instead of Glue Workflows?

**Senior Answer:**

"Both can orchestrate Glue jobs, but Step Functions wins for production:

| Feature | Glue Workflows | Step Functions |
|---------|---------------|----------------|
| Error handling | Basic (retry or fail) | Rich (catch, retry with backoff, fallback) |
| Notifications | Must add manually | Built-in SNS integration |
| Visibility | Glue console only | Visual workflow + CloudWatch |
| Cross-service | Glue jobs only | Any AWS service (Lambda, ECS, EMR, etc.) |
| Conditional logic | Limited | Full choice/parallel/map states |
| Cost | Free (but less capable) | ~$0.025 per 1000 transitions |
| Input passing | Fixed | Dynamic (JSON path) |
| Audit trail | Basic | Full execution history |

**For our pipeline, Step Functions lets us:**
1. Run Bronze → wait for success → run Silver → wait → run Gold
2. On Bronze failure: send alert, don't run Silver/Gold
3. On Silver failure: send alert, don't run Gold (Bronze is safe)
4. On Gold failure: send alert (Bronze + Silver are safe)
5. Pass `run_date` dynamically from EventBridge schedule
6. Add future steps (data quality checks, notifications, triggers) easily

**The Step Function state machine is self-documenting:**
```
RunBronze → (success) → RunSilver → (success) → RunGold → PipelineSuccess
    ↓ (failure)              ↓ (failure)            ↓ (failure)
 BronzeFailed            SilverFailed            GoldFailed
    ↓                        ↓                      ↓
 SNS Alert               SNS Alert              SNS Alert
```"

---

## Q11: Why give `AdministratorAccess` to a Glue job is a P0 security issue?

**Senior Answer:**

"The junior attached:
```hcl
policy_arn = 'arn:aws:iam::aws:policy/AdministratorAccess'
```

This gives the Glue job permission to:
- Delete ANY S3 bucket in the account (including backups, other teams' data)
- Drop ANY DynamoDB table
- Modify IAM roles (escalate privileges)
- Launch EC2 instances (crypto mining)
- Access ANY secret in Secrets Manager
- Delete CloudTrail logs (cover tracks)

**Attack scenarios:**
1. **Supply chain attack** — A compromised PyPI dependency in the Glue job gets
   admin access to the entire AWS account
2. **Data exfiltration** — Glue job reads sensitive data from other teams' buckets
3. **Lateral movement** — Attacker uses Glue's admin role to escalate to any service
4. **Accidental damage** — Bug in code deletes wrong bucket

**The senior's approach — least privilege per layer:**
```hcl
# Bronze can ONLY: read raw, write bronze, write dead letter
# Silver can ONLY: read bronze, write silver, write dead letter
# Gold can ONLY: read silver, write gold
# NONE can: delete buckets, modify IAM, access other services
```

Each job has exactly the permissions it needs, nothing more. A compromised Gold job
can't touch Bronze data. A bug in Bronze can't delete Silver."

---

## Q12: Walk through what happens when today's data has 15% corrupt records.

**Senior Answer (Bronze → Silver flow):**

"**Bronze layer (10% threshold):**
```python
error_rate = corrupt_count / total_count  # 15%
if error_rate > 0.10:  # Bronze threshold = 10%
    raise RuntimeError('Quality gate FAILED: 15% exceeds 10% threshold')
```

**What happens:**
1. Bronze job FAILS immediately — does not write corrupt data
2. Step Functions catches the failure → routes to `BronzeFailed` state
3. SNS alert: '🚨 BRONZE ETL FAILED'
4. Silver and Gold do NOT run (pipeline halted)
5. Data engineer investigates:
   - Is the source system sending bad data?
   - Did the schema change?
   - Is it a one-time blip or systematic?

**If the junior's code was running:**
1. No quality gate → all 15% corrupt records flow through
2. Bronze: dumps everything including garbage
3. Silver: tries to compute `quantity * price` on garbage → nulls or wrong numbers
4. Gold: aggregations include garbage → dashboards show wrong KPIs
5. Executives make decisions based on wrong data
6. No one notices until quarterly reconciliation fails

**The quality gate philosophy:**
- Bronze: 10% threshold (raw data may have some issues)
- Silver: 5% threshold (cleansed data should be cleaner)
- Gold: 0% threshold (business data must be perfect)

Better to HALT the pipeline and alert than to silently propagate bad data."

---

## QUICK-FIRE QUESTIONS

---

**Q13: `spark.read.json()` vs `spark.read.schema(MY_SCHEMA).json()` — why does it matter?**

"Without schema, Spark INFERS types by scanning data. This is:
1. Expensive (reads data twice)
2. Non-deterministic (today price is `10` → Long, tomorrow `10.5` → Double)
3. Nullable by default (can't catch missing fields)

With explicit schema: types are fixed, nullability is enforced, corrupt records are
caught immediately. For financial data, schema enforcement is non-negotiable."

---

**Q14: What is Adaptive Query Execution (AQE) and why enable it?**

"AQE optimizes Spark queries at RUNTIME based on actual data statistics (not just
estimates). It does three things:
1. **Coalesces shuffle partitions** — Merges tiny partitions into larger ones (fewer files)
2. **Switches join strategies** — Converts sort-merge to broadcast join if one side is small
3. **Handles skew** — Splits skewed partitions into smaller chunks

Enable with: `spark.sql.adaptive.enabled = true`
This is especially valuable for our pipeline because trade data is skewed (AAPL has
1M trades, some penny stocks have 100). AQE handles this automatically."

---

**Q15: Why separate Glue Catalog databases per layer?**

"1. **Access control** — Analysts query Gold only, not raw Bronze
2. **Discovery** — Users find `gold_db.daily_trading_summary` not `mixed_db.table_47`
3. **Lifecycle** — Can drop/recreate Bronze tables without touching Gold
4. **Naming** — Same logical table name in each layer: `bronze.trades`, `silver.trades`
5. **Lake Formation** — Can grant permissions at database level"

---

**Q16: Why does the senior enable Spark UI logs in Glue?**

"`--enable-spark-ui = true` + `--spark-event-logs-path = s3://...`

This saves the Spark execution plan, stage timings, and DAG visualization. When a
job takes 2 hours instead of 20 minutes, you can:
1. Open Spark UI history server
2. See which stage was slow
3. Identify data skew, excessive shuffles, or spills to disk
4. Optimize the specific bottleneck

Without it, debugging slow jobs requires adding print statements and rerunning —
expensive and time-consuming."

---

**Q17: The junior has no `job.commit()`. What breaks?**

"Glue bookmarks track which files have been processed. `job.commit()` SAVES the
bookmark state. Without it:
- Run 1: processes files A, B, C → bookmark state NOT saved
- Run 2: bookmark says 'nothing processed yet' → reprocesses A, B, C again
- Result: duplicates every single run, growing exponentially

It's like saving a game — if you don't save, you restart from the beginning every time."

---

**Q18: Why `G.2X` worker type instead of default `G.1X`?**

"| Worker | vCPU | Memory | Use Case |
|--------|------|--------|----------|
| G.1X | 4 | 16 GB | Small datasets, simple transforms |
| G.2X | 8 | 32 GB | Medium datasets, complex joins/aggregations |
| G.4X | 16 | 64 GB | Large datasets, ML workloads |
| G.8X | 32 | 128 GB | Very large datasets, memory-intensive |

For financial trade data with:
- Decimal arithmetic (more memory than floats)
- Multiple aggregations in Gold
- Deduplication windows in Silver
- Quality validation (multiple passes)

G.2X is the right balance of cost and performance. G.1X would OOM on the Silver
deduplication window over millions of records."

---
