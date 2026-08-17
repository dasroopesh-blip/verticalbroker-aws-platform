# Interview Practice: Senior vs Junior Code Review

This folder contains complete interview practice materials for **Python Lambda**, **Terraform IaC**, and **Spark/Glue ETL** — all based on the Vertical Broker trading platform.

## Format

Each section follows the same pattern:
1. **Senior developer's code** — production-ready, correct implementation
2. **Junior developer's code** — annotated with errors (P0/P1/P2 severity)
3. **Peer review document** — detailed error identification with fixes and test strategies
4. **Q&A practice** — interview questions with senior-level answers

---

## 📁 Folder Structure

```
docs/interview-practice/
├── README.md (this file)
├── python/
│   ├── senior_trade_processor.py      ✅ Production Lambda (correct)
│   ├── junior_trade_processor.py      ❌ 14 errors annotated
│   ├── corrected_trade_processor.py   ✅ Junior's code fixed (with fix # annotations)
│   ├── PEER_REVIEW.md                 📋 Detailed peer review (14 findings)
│   └── QA_PRACTICE_SESSION.md         🎯 25 interview Q&A questions
├── terraform/
│   ├── terraform_senior_main.tf       ✅ Production Lambda infra
│   ├── terraform_junior_main.tf       ❌ 20 errors (wildcard IAM, no DLQ, etc.)
│   ├── terraform_senior_spark.tf      ✅ EMR Serverless + Step Functions
│   ├── terraform_senior_glue.tf       ✅ Glue Bronze/Silver/Gold + orchestration
│   ├── terraform_junior_glue.tf       ❌ 17 errors (AdministratorAccess!)
│   └── TERRAFORM_PEER_REVIEW.md       📋 Terraform peer review (20 findings)
└── spark-glue/
    ├── spark_senior_etl.py            ✅ Standalone Spark ETL (correct)
    ├── spark_junior_etl.py            ❌ 20 errors annotated
    ├── glue_senior_bronze.py          ✅ Bronze layer Glue job
    ├── glue_senior_silver.py          ✅ Silver layer Glue job
    ├── glue_senior_gold.py            ✅ Gold layer Glue job
    ├── glue_junior_etl.py             ❌ 25 errors (monolithic, no validation)
    ├── SPARK_GLUE_PEER_REVIEW.md      📋 Spark/Glue peer review (25+17 findings)
    └── SPARK_GLUE_QA_SESSION.md       🎯 18 Spark/Glue Q&A questions
```

---

## Key Topics Covered

### Python / Lambda
- SQS `ReportBatchItemFailures` vs `statusCode: 200`
- TOCTOU race condition in idempotency (get-then-put vs conditional write)
- `Decimal` vs `float` for financial calculations
- PII-safe structured logging
- Input validation strategies
- Two-tier error handling (validation vs transient)

### Terraform
- Least-privilege IAM (specific actions on specific ARNs)
- SQS DLQ + `function_response_types = ["ReportBatchItemFailures"]`
- S3 hardening (encryption, public access block, versioning, lifecycle)
- DynamoDB PAY_PER_REQUEST vs PROVISIONED
- CloudWatch alarms for operational visibility
- Environment isolation (no hardcoded prod defaults)

### Spark / Glue
- Bronze/Silver/Gold medallion architecture
- Schema enforcement vs inference
- `DecimalType` for financial columns
- `mode("overwrite") + partitionBy` for idempotent writes
- Glue Bookmarks + `job.commit()`
- Quality gates (fail pipeline if error rate > threshold)
- Step Functions orchestration (Bronze → Silver → Gold)
- `repartition(1)` anti-pattern

---

## How to Use

1. **Self-study:** Read the junior code first, try to find errors yourself, then check the peer review
2. **Mock interview:** Have someone quiz you from the Q&A documents
3. **Code review practice:** Practice giving feedback on the junior code as if in a real PR review
4. **Architecture discussion:** Use the diagrams and design doc as talking points

---

## Error Severity Classification

| Level | Definition | Examples |
|-------|-----------|----------|
| **P0** | Message loss, duplicate financial action, incorrect money, security breach | Silent SQS message deletion, TOCTOU race, float money, PII in logs |
| **P1** | Reliability or operational risk | No retry config, wrong visibility timeout, no monitoring |
| **P2** | Maintainability or improvement | No structured logging, no tags, deprecated APIs |
