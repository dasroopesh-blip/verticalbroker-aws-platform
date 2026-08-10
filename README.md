# VerticalBroker AWS Data Engineering Platform

> **Interview Preparation Project** — Vertical Relevance Technical Pairing Interview
> FINRA-regulated brokerage | 200M monthly users | 100M trade datapoints/day | 10 PB data estate

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Project Structure](#project-structure)
4. [Terraform Modules](#terraform-modules)
5. [Python Application Code](#python-application-code)
6. [Data Pipeline (ETL)](#data-pipeline-etl)
7. [Event-Driven Architecture](#event-driven-architecture)
8. [ML/RL Advisory Pipeline](#mlrl-advisory-pipeline)
9. [Security & Compliance](#security--compliance)
10. [Monitoring & Observability](#monitoring--observability)
11. [Interview Exercise Guides](#interview-exercise-guides)
12. [How to Use This Repo](#how-to-use-this-repo)

---

## Overview

This is a **complete, production-grade AWS data engineering platform** for VerticalBroker — a FINRA-regulated brokerage firm. It demonstrates:

| Dimension | Details |
|-----------|---------|
| **Scale** | 100M datapoints/day (~1,157/sec avg, 12,000/sec burst) |
| **Data Estate** | 10 PB across Bronze/Silver/Gold medallion layers |
| **Users** | 200M monthly (50M mobile, 60M desktop) |
| **Products** | Full-Service, Self-Service, Automated (RL advisor) |
| **Compliance** | FINRA 4511, SEC, SIPC, SOC 2 Type II |
| **IaC** | 100% Terraform (68 files, 8 modules) |
| **Code** | 100% Python (37 files, Lambda + PySpark) |

### Technology Stack

- **Infrastructure**: Terraform 1.5+ / AWS Provider 5.x
- **Compute**: AWS Lambda (Python 3.12, ARM64/Graviton2)
- **Streaming**: Kinesis Data Streams, EventBridge, SQS FIFO
- **ETL**: AWS Glue PySpark (G.2X workers, auto-scaling)
- **Storage**: S3 (Parquet/Snappy), DynamoDB, Neptune, OpenSearch
- **ML**: Amazon SageMaker (RL/PPO training, real-time inference)
- **Security**: KMS, IAM, Lake Formation, Cognito, GuardDuty
- **Observability**: CloudWatch, X-Ray, SSM Automation

---

## Architecture

### Three-Lane System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                    LANE 1: TRANSACTIONAL TRADING                      │
│                                                                       │
│  [Bloomberg B-Pipe] ──► [Kinesis 16 shards] ──► [Lambda: MarketData] │
│  [Thomson Reuters]  ──►                                               │
│  [Clients] ──► [API Gateway + Cognito] ──► [Lambda: OrderManager]    │
│                                          ──► [Lambda: WalletService]  │
│                                          ──► [Lambda: AdvisoryAgent]  │
│  [DynamoDB: Orders, Portfolio, Idempotency, CircuitBreaker]          │
├─────────────────────────────────────────────────────────────────────┤
│                    LANE 2: EVENT + LAKEHOUSE                          │
│                                                                       │
│  [EventBridge] ──► [Step Functions Orchestrator]                      │
│  [SQS FIFO]   ──► [Glue PySpark: Bronze→Silver→Gold]                │
│  [DMS CDC]    ──► [S3 Bronze (raw)] → [S3 Silver (validated)]        │
│                    → [S3 Gold (aggregated)]                           │
│  [Glue Data Catalog + Lake Formation governance]                      │
├─────────────────────────────────────────────────────────────────────┤
│                    LANE 3: ML + CONSUMPTION                           │
│                                                                       │
│  [SageMaker: RL Training (PPO)] → [Model Registry] → [Endpoint A/B] │
│  [OpenSearch: full-text search, dashboards, ISM lifecycle]            │
│  [Neptune: graph analytics, fraud detection (Gremlin)]                │
│  [Athena: SQL queries with workgroup cost controls]                   │
├─────────────────────────────────────────────────────────────────────┤
│                    CROSS-CUTTING CONTROLS                             │
│                                                                       │
│  [Multi-Account: Organizations + Transit Gateway + VPC Endpoints]     │
│  [Security: KMS per classification, IAM least-privilege, GuardDuty]   │
│  [Monitoring: CloudWatch 9 alarms + 3 composite, X-Ray, SSM Runbooks]│
│  [DR: Cross-region replication, Route 53 failover, RTO 4h / RPO 1h]  │
└─────────────────────────────────────────────────────────────────────┘
```

### Scale Calculations

| Metric | Value | Design Consequence |
|--------|-------|--------------------|
| 100M datapoints/day | 1,157/sec average | Never size from average alone |
| Burst (10x) | 12,000/sec | Kinesis: 16 shards (12 + 33% headroom) |
| Record size | ~1 KB | 200-500 GB/day raw ingestion |
| Data estate | 10 PB | Incremental/CDC, no full reloads |
| Monthly users | 200M | API Gateway: 10K req/sec rate limit |

---

## Project Structure

```
verticalbroker-aws-platform/
├── README.md                          ← You are here
├── .kiro/specs/verticalbroker-data-platform/
│   ├── requirements.md                ← 20 detailed requirements
│   ├── design.md                      ← HLD + LLD (2500 lines)
│   └── tasks.md                       ← 38 implementation tasks
│
├── terraform/                         ← 100% Infrastructure as Code
│   ├── main.tf                        ← Root module composition
│   ├── variables.tf                   ← Root variables with tag validation
│   ├── versions.tf                    ← Terraform 1.5+ / AWS 5.x
│   ├── outputs.tf                     ← Platform-wide outputs
│   ├── terragrunt.hcl                 ← DRY configuration management
│   ├── environments/
│   │   ├── dev/                       ← Dev backend + tfvars
│   │   ├── staging/                   ← Staging backend + tfvars
│   │   ├── production/                ← Production backend + tfvars
│   │   └── dr/                        ← Disaster recovery backend + tfvars
│   ├── global/
│   │   ├── organizations.tf           ← AWS Organizations + SCPs
│   │   └── baseline_security.tf       ← GuardDuty, SecurityHub, CloudTrail
│   └── modules/
│       ├── networking/                ← VPC, Transit Gateway, VPC Endpoints, SGs
│       ├── security/                  ← KMS, IAM roles/policies, detection
│       ├── data-lake/                 ← S3 buckets, Glue Catalog, Lake Formation
│       ├── streaming/                 ← Kinesis, EventBridge, SQS, DMS
│       ├── compute/                   ← Lambda, API Gateway, Cognito, Step Functions
│       ├── analytics/                 ← OpenSearch, Neptune, Athena
│       ├── ml/                        ← SageMaker Domain, Endpoint, Pipeline
│       └── monitoring/                ← CloudWatch, SNS, X-Ray, SSM, Budgets
│
└── src/                               ← 100% Python Application Code
    ├── common/                        ← Shared utilities (all Lambda functions use these)
    │   ├── idempotency.py             ← DynamoDB-based idempotency (24h TTL)
    │   ├── circuit_breaker.py         ← Distributed circuit breaker (DynamoDB-backed)
    │   ├── retry.py                   ← Exponential backoff with jitter
    │   ├── dlq_handler.py             ← Dead-letter queue processor
    │   └── outbox.py                  ← Transactional outbox pattern
    ├── models/                        ← Shared data models
    │   ├── market_data.py             ← MarketDataRaw/Silver/Gold dataclasses
    │   ├── trade.py                   ← TradeEvent, OrderRequest, ClientProfile
    │   └── events.py                  ← EventBridge event schemas
    ├── services/                      ← Lambda function handlers
    │   ├── market_data/               ← Kinesis → S3 Bronze (Parquet)
    │   ├── order_manager/             ← API Gateway → DynamoDB (idempotent)
    │   ├── wallet/                    ← Portfolio + margin (SQS FIFO consumer)
    │   ├── advisory_agent/            ← SageMaker RL inference + FINRA logging
    │   └── cdc/                       ← Schema evolution handler
    ├── etl/                           ← Glue PySpark jobs
    │   ├── bronze_to_silver.py        ← Cleanse, validate, deduplicate
    │   ├── silver_to_gold.py          ← Aggregate (VWAP, VaR, RSI, portfolios)
    │   └── data_quality.py            ← Quality framework (severity-based)
    ├── ml/                            ← SageMaker ML pipeline
    │   ├── training_pipeline.py       ← PPO RL training (4-step pipeline)
    │   └── model_governance.py        ← Bias, fairness, SHAP, approval gate
    ├── analytics/                     ← Graph analytics
    │   └── graph_model.py             ← Neptune vertices, edges, fraud queries
    └── orchestration/                 ← Step Functions
        └── pipeline_state_machine.py  ← ASL definition (7 states)
```

---

## Terraform Modules

### Module 1: Networking (`terraform/modules/networking/`)

| File | Resources | Purpose |
|------|-----------|---------|
| `main.tf` | VPC, 6 subnets (3 AZs × 2 tiers), route tables, NACLs, flow logs | Private-only networking |
| `transit_gateway.tf` | TGW, 3 route tables, blackhole routes, RAM share | Prod/non-prod isolation |
| `vpc_endpoints.tf` | S3 Gateway, Glue, KMS, SQS, EventBridge, CloudWatch, DynamoDB, STS, API Gateway PrivateLink | No internet access needed |
| `security_groups.tf` | 6 SGs: data, compute, analytics, database, streaming, ML tier | Deny-by-default, explicit allow |

### Module 2: Security (`terraform/modules/security/`)

| File | Resources | Purpose |
|------|-----------|---------|
| `kms_keys.tf` | 4 CMKs (Public/Internal/Confidential/Restricted) + DR replicas | Encryption per classification |
| `iam_roles.tf` | 5 roles + permission boundary | Least-privilege per service |
| `iam_policies.tf` | 5 policies (no wildcard resources) | Scoped actions + ARNs |
| `guardduty.tf` | Detector, threat intel, SNS alerts | Threat detection <60s |
| `security_hub.tf` | FSBP + CIS standards, action targets | SOC 2 evidence |
| `cloudtrail.tf` | Data events trail, metric filters, alarms | FINRA audit trail |
| `config_rules.tf` | 3 conformance packs + 6 individual rules | Continuous compliance |

### Module 3: Data Lake (`terraform/modules/data-lake/`)

| File | Resources | Purpose |
|------|-----------|---------|
| `s3_buckets.tf` | 4 buckets (Bronze/Silver/Gold/Regulatory) with Object Lock | Medallion architecture |
| `lifecycle.tf` | Intelligent-Tiering → Glacier Deep Archive (90d) | Cost optimization for 10 PB |
| `encryption.tf` | KMS SSE per bucket, bucket keys enabled | At-rest encryption |
| `replication.tf` | CRR to us-west-2, RTC (15-min target), CloudWatch alarms | Disaster recovery |
| `glue_catalog.tf` | 3 databases, 6 tables, 3 crawlers | Schema registry |
| `lake_formation.tf` | Column-level PII security, role-based access | Data governance |
| `glue_jobs.tf` | Bronze→Silver + Silver→Gold jobs, G.2X, auto-scaling | ETL execution |

### Module 4: Streaming (`terraform/modules/streaming/`)

| File | Resources | Purpose |
|------|-----------|---------|
| `kinesis.tf` | Market data stream (16 shards, ON_DEMAND), enhanced fan-out | 12K/sec burst ingestion |
| `eventbridge.tf` | Event bus, 5 schemas, 5 routing rules, archive, DLQ | Event-driven decoupling |
| `sqs.tf` | 5 queues + 5 DLQs (FIFO + Standard), KMS, long polling | Reliable async processing |
| `dms.tf` | Replication instance, source/target endpoints, CDC task | Change data capture |

### Module 5: Compute (`terraform/modules/compute/`)

| File | Resources | Purpose |
|------|-----------|---------|
| `lambda_functions.tf` | 7 Lambda functions, event sources, provisioned concurrency | Serverless compute |
| `lambda_layers.tf` | 3 layers (dependencies, utilities, models) | Shared code |
| `api_gateway.tf` | HTTP API (8 routes) + WebSocket API (market data streaming) | REST + real-time APIs |
| `cognito.tf` | User Pool (MFA), resource server (8 scopes), identity pool | JWT authentication |
| `step_functions.tf` | Pipeline orchestrator (7 states), IAM, logging | ETL coordination |
| `dynamodb.tf` | 5 tables (Idempotency, CircuitBreaker, Orders, Outbox, Portfolio) | State management |
| `aurora_postgresql.tf` | Aurora PostgreSQL Serverless v2 (1 writer + 2 readers), Multi-AZ, KMS, CDC source | ACID ledger (source of truth) |

### Module 6: Analytics (`terraform/modules/analytics/`)

| File | Resources | Purpose |
|------|-----------|---------|
| `opensearch.tf` | Multi-AZ domain (3 master + 6 data + UltraWarm), ISM lifecycle | Search + dashboards |
| `neptune.tf` | Cluster (1W + 2R), auto-scale at 70% CPU, bulk loader | Graph fraud detection |
| `athena.tf` | 3 workgroups, 1TB/query limit, named queries, results bucket | SQL analytics |

### Module 7: ML (`terraform/modules/ml/`)

| File | Resources | Purpose |
|------|-----------|---------|
| `sagemaker.tf` | Domain, endpoint (A/B 90/10), auto-scaling, 4 monitors | RL inference |
| `sagemaker_pipelines.tf` | 4-step pipeline, weekly schedule, artifact lifecycle | Model training |

### Module 8: Monitoring (`terraform/modules/monitoring/`)

| File | Resources | Purpose |
|------|-----------|---------|
| `cloudwatch.tf` | 5 dashboards, 9 alarms, 3 composite alarms | Observability |
| `sns.tf` | 3 topics (ops/security/cost), KMS encryption | Alerting |
| `xray.tf` | 3 sampling rules, 5 service groups | Distributed tracing |
| `ssm_automation.tf` | 3 runbooks, alarm→automation triggers | Self-healing |
| `budgets.tf` | Per-CostCenter budgets, total budget, CUR reports | Cost control |

---

## Python Application Code

### Lambda Services

#### Market Data Processor (`src/services/market_data/handler.py`)
- **Trigger**: Kinesis Data Streams (batch size 100, parallelization 10)
- **Purpose**: Ingest Bloomberg B-Pipe + Thomson Reuters → S3 Bronze (Parquet)
- **Key patterns**: BatchProcessor, schema validation, Parquet micro-batch write, Glue partition registration, DLQ routing, EventBridge emission

#### Order Manager (`src/services/order_manager/handler.py`)
- **Trigger**: API Gateway (POST /v1/orders, GET /v1/orders/{id})
- **Purpose**: Idempotent order submission with pre-trade validation
- **Key patterns**: @idempotent decorator (24h TTL), transactional outbox (DynamoDB), margin check, position limits, market hours validation

#### Wallet Service (`src/services/wallet/handler.py`)
- **Trigger**: API Gateway (GET /v1/portfolio) + SQS FIFO (trade-processing.fifo)
- **Purpose**: Portfolio management, position updates, margin validation
- **Key patterns**: Weighted avg cost basis, Decimal for money, batch item failure reporting, Reg T margin (50%)

#### Advisory Agent (`src/services/advisory_agent/handler.py`)
- **Trigger**: API Gateway (POST /v1/advisory)
- **Purpose**: RL-powered investment recommendations with FINRA compliance
- **Key patterns**: SageMaker invoke (<500ms SLA), governance (confidence <0.7 → human review), S3 Object Lock COMPLIANCE logging, EventBridge emission

### Common Utilities (`src/common/`)

| Module | Pattern | Purpose |
|--------|---------|---------|
| `idempotency.py` | DynamoDB Powertools | Prevent duplicate processing (24h TTL) |
| `circuit_breaker.py` | DynamoDB state machine | Prevent cascade failures (5 failures → open) |
| `retry.py` | Exponential backoff + jitter | Transient failure recovery (3 attempts, 5-min max) |
| `outbox.py` | Transactional write | Atomic business state + event emission |
| `dlq_handler.py` | EventBridge + CloudWatch | Failed message investigation + alerting |

---

## Data Pipeline (ETL)

### Bronze → Silver (`src/etl/bronze_to_silver.py`)

```
Extract (Glue Catalog) → Validate Schema → Deduplicate (composite key) →
Apply Data Quality → Write Silver (Parquet/Snappy) → Record Lineage
```

- **Deduplication**: instrument_id + source_timestamp + source_id (Window function, keep latest)
- **Quality abort**: >30% rejection rate → halt batch, emit quality.failed event
- **Output**: Parquet/Snappy, partitioned by instrument_type + trade_date
- **SLA**: Complete within 60 minutes (G.2X, max 100 DPUs)

### Silver → Gold (`src/etl/silver_to_gold.py`)

Produces 4 Gold datasets:
1. **daily_trade_summaries**: OHLCV, VWAP, trade_count (Window functions for open/close)
2. **client_portfolio_snapshots**: Cumulative positions, avg cost basis, unrealized P&L
3. **instrument_performance**: Rolling 1d/5d/20d/60d/252d returns, volatility, Sharpe, RSI
4. **risk_exposure_aggregates**: VaR (95th percentile), expected shortfall, beta

- **No Python UDFs** — all PySpark built-in functions for Catalyst optimization
- **DecimalType** for money (18,8 precision)
- **Incremental**: CDC markers filter to new/updated records only

### Data Quality Framework (`src/etl/data_quality.py`)

| Rule Type | HIGH Severity (halt) | LOW Severity (tag + continue) |
|-----------|---------------------|-------------------------------|
| Schema | Any failure | — |
| Null rate | >3× threshold (15%) | Exceeded but <3× (5-15%) |
| Range | ≥1% violations | <1% violations |
| Referential integrity | >1% orphans | ≤1% orphans |
| Freshness | ≥2× SLA missed (48h) | <2× SLA missed (24-48h) |

Score: 0-100 weighted (completeness 30%, accuracy 30%, consistency 25%, timeliness 15%)

---

## Event-Driven Architecture

### EventBridge Event Flows

```
verticalbroker.market-data/MarketDataIngested  → Step Functions (ETL orchestrator)
verticalbroker.order-manager/TradeExecuted     → SQS FIFO (wallet position update)
verticalbroker.etl-engine/PipelineExecutionFailed → CloudWatch Logs + SNS (ops team)
verticalbroker.security/ComplianceAlert        → SNS (security team)
verticalbroker.advisory-agent/AdvisoryGenerated → CloudWatch Logs (audit trail)
```

### Step Functions Orchestrator

```
ValidateInput → CheckPartition → BronzeToSilver (Glue, 3x retry/60s/2.0)
→ SilverToGold (Glue, 3x retry/60s/2.0) → TriggerIndexing [OpenSearch || Neptune]
→ EmitSuccess
```

---

## ML/RL Advisory Pipeline

### Training Pipeline (SageMaker)

```
FeatureEngineering (ml.m5.xlarge) → Training PPO (ml.p3.2xlarge, lr=0.0003, 
gamma=0.99, 10K episodes) → Evaluation (bias + fairness + SHAP) → 
Registration (Model Registry, PendingManualApproval)
```

### Model Governance Gate

| Check | Threshold | Action if Failed |
|-------|-----------|-----------------|
| Bias detection | 5% max deviation across age/income/filing groups | REJECTED |
| Fairness metrics | 5% max group deviation | REJECTED |
| Explainability | SHAP report available | PENDING_REVIEW |
| All pass | — | APPROVED + conditions |

### Inference

- **Endpoint**: A/B testing (90% production / 10% canary)
- **SLA**: <500ms P95 latency
- **Governance**: confidence <0.7 → requires_human_review = True
- **Compliance**: ALL recommendations logged to S3 Object Lock COMPLIANCE (7-year FINRA 4511)

---

## Security & Compliance

### Encryption (KMS CMKs)

| Classification | Key | Used By |
|---------------|-----|---------|
| Public | Public CMK | Reference data |
| Internal | Internal CMK | Logs, metrics, Terraform state |
| Confidential | Confidential CMK | Bronze/Silver/Gold trade data |
| Restricted | Restricted CMK | PII, regulatory store, advisory logs |

### IAM Least-Privilege (No Wildcards)

| Role | Trust | Key Permissions |
|------|-------|----------------|
| MarketDataLambda | lambda.amazonaws.com | Kinesis read, S3 Bronze write, Glue partition, EventBridge put |
| ETLGlue | glue.amazonaws.com | S3 read Bronze/Silver, write Silver/Gold, Glue catalog |
| AdvisoryAgent | lambda.amazonaws.com | SageMaker invoke, Regulatory Store write (Object Lock condition) |
| OrderManager | lambda.amazonaws.com | DynamoDB Orders + Idempotency, EventBridge, SQS FIFO |
| WalletService | lambda.amazonaws.com | DynamoDB Portfolio, SQS trade-processing read |

### FINRA Compliance

- **Rule 4511**: 7-year immutable retention (S3 Object Lock COMPLIANCE mode)
- **Audit trail**: CloudTrail data events (S3, Lambda, DynamoDB)
- **PII protection**: Lake Formation column-level security (client_name, ssn, account_number)
- **SOC 2**: Security Hub FSBP + CIS, Config conformance packs, automated evidence

---

## Monitoring & Observability

### 9 Critical Alarms

1. `pipeline-latency-sla-breach` — ETL exceeds 300s
2. `api-error-rate-above-1pct` — 5xx/total > 1%
3. `lambda-throttling-detected` — Any throttle event
4. `sqs-depth-above-10k` — Queue backlog
5. `infrastructure-cpu-above-80pct` — Neptune/OpenSearch
6. `cdc-replication-lag-above-60s` — DMS falling behind
7. `kinesis-iterator-age-above-5s` — Consumer lag
8. `glue-job-failure` — ETL job failed
9. `cost-budget-80pct-threshold` — Spend approaching limit

### 3 Composite Alarms (Cascade Detection)

- Pipeline latency + SQS depth + Kinesis lag = **data pipeline cascade**
- API errors + Lambda throttling = **compute cascade**
- CPU high + CDC lag = **infrastructure saturation**

### Automated Remediation (SSM Runbooks)

- Glue job failure alarm → **restart-failed-pipeline** (auto-restart)
- Pipeline latency alarm → **scale-glue-capacity** (increase DPUs to 75)
- Security event → **rotate-credentials** (Secrets Manager rotation)

---

## Interview Exercise Guides

### Architecture Exercise (12 minutes)

1. Draw 3 lanes: Transactional Trading | Event + Lakehouse | ML + Consumption
2. Show: Kinesis → Bronze → Silver → Gold flow
3. Highlight: Aurora ledger truth, EventBridge decoupling, idempotent consumers
4. Defend: Kinesis over Kafka (AWS-native, auto-scaling, lower ops)
5. Migration: Capture → Lakehouse → Strangler → Dual-run → Cutover

### Terraform IaC Exercise (15 minutes)

**Review order**: Parse → Identity → Data security → Reliability → Operations → Delivery → Cost

Key files to review:
- `terraform/modules/security/iam_policies.tf` — Least-privilege examples
- `terraform/modules/data-lake/s3_buckets.tf` — Object Lock, encryption, TLS-only
- `terraform/modules/streaming/kinesis.tf` — Capacity planning
- `terraform/modules/compute/lambda_functions.tf` — Event source mappings

### Python Coding Exercise (15 minutes)

Key files demonstrating production patterns:
- `src/services/market_data/handler.py` — Batch processing, validation, Parquet write
- `src/services/order_manager/handler.py` — Idempotency, transactional outbox
- `src/common/circuit_breaker.py` — Distributed state machine
- `src/etl/bronze_to_silver.py` — PySpark with explicit schema, dedup, quality

**Defects to catch in bad code**: Hard-coded keys, SQL injection, float for money, swallowed exceptions, unbounded memory, no idempotency, commit-per-row, mutable defaults, PII in logs.

---

## How to Use This Repo

### For Interview Prep

1. **Architecture**: Study the 3-lane diagram and scale calculations above
2. **Terraform**: Review `terraform/modules/security/` for IaC exercise patterns
3. **Python**: Review `src/services/` for production Lambda patterns
4. **PySpark**: Review `src/etl/` for distributed processing patterns
5. **Stories**: Map Census/PBGC/Amtrak experience to VerticalBroker components

### For Deployment (if needed)

```bash
# Initialize Terraform
cd terraform/environments/dev
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply

# Deploy Lambda code
cd src/
zip -r ../lambda-package.zip .
aws s3 cp lambda-package.zip s3://vb-artifacts-dev/lambda-packages/

# Deploy Glue scripts
aws s3 sync src/etl/ s3://vb-glue-scripts-dev/src/etl/
```

---

## Key Design Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Kinesis over Kafka | AWS-native, auto-scaling shards, lower ops | Interview: state criteria, not preferences |
| Glue over EMR | Serverless, auto-scaling DPUs, catalog integration | Minimize operational burden |
| Parquet over Iceberg | Athena-native, proven at 10PB, cost-effective | Standardize per workload |
| Neptune over Neo4j | Managed, IAM-integrated, Gremlin API | Fraud detection use case |
| SageMaker RL over custom | Model registry, A/B testing, built-in monitoring | Governance + compliance |
| EventBridge over direct calls | Schema registry, archive, loose coupling | Scale independently |

---

## License

Private preparation material for Vertical Relevance technical pairing interview.


---

## Database Architecture Summary

| Database | Type | Purpose | Consistency |
|----------|------|---------|-------------|
| **Aurora PostgreSQL** | Relational (ACID) | Order/Wallet/Ledger — **source of truth** | Strong (synchronous) |
| **DynamoDB** | Key-Value/Document | Lambda operational state (idempotency, outbox, circuit breaker) | Per-item ACID transactions |
| **Neptune** | Graph (Gremlin) | Fraud detection, client networks, instrument correlations | Eventual |
| **OpenSearch** | Search/Analytics | Full-text search, dashboards, near-real-time analytics | Eventual (~10 min lag) |
| **S3 (Parquet)** | Object/Data Lake | Bronze/Silver/Gold medallion layers (10 PB) | Immutable (Object Lock) |
| **Athena** | SQL Engine | Ad-hoc queries against S3 data lake | Read-only |

### Data Flow: Aurora → CDC → Lake → Analytics → ML

```
[Aurora PostgreSQL]  ←── ACID writes (orders, wallets, trades)
        │
        │ DMS CDC (< 30s latency, full-load + ongoing replication)
        ▼
[S3 Bronze Layer]  ──► [Glue PySpark] ──► [S3 Silver] ──► [S3 Gold]
                                                              │
                              ┌────────────────┬──────────────┼──────────────┐
                              ▼                ▼              ▼              ▼
                        [OpenSearch]      [Neptune]      [Athena]     [SageMaker RL]
                        (search/dash)    (fraud/graph)   (SQL)        (training)
```

### Key Interview Answer: "Why Not Just DynamoDB for Everything?"

> Aurora PostgreSQL is the **ledger truth** because:
> - ACID transactions across multiple tables (order + wallet + position in one commit)
> - SQL joins for reconciliation and regulatory reporting
> - CDC/logical replication for downstream decoupling
> - FINRA requires auditable, relational transaction history
>
> DynamoDB is used **only** for Lambda operational patterns:
> - Idempotency tokens (24h TTL, single-key access)
> - Circuit breaker state (single-key conditional writes)
> - Transactional outbox (DynamoDB Streams → EventBridge)
> - Portfolio position cache (fast key-value lookups)
>
> "I separate the strongly-consistent write path from the replayable analytical path, then connect them through durable, governed events."

