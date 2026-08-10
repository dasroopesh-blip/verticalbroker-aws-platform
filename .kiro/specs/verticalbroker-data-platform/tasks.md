# Implementation Plan: VerticalBroker AWS Data Engineering Platform

## Overview

This implementation plan converts the VerticalBroker platform design into discrete coding tasks for a FINRA-regulated brokerage data platform handling 100M datapoints/day across a 10 PB data estate. All infrastructure is Terraform 1.5+ and all application code is Python 3.12. Tasks are ordered to establish foundational infrastructure first, then build upward through data, compute, analytics, ML, and cross-cutting concerns.

## Tasks

- [x] 1. Foundation: Terraform State, Organizations, and Networking

  - [x] 1.1 Create Terraform project structure and backend configuration
    - Create directory structure: `terraform/modules/`, `terraform/environments/{dev,staging,production,dr}/`, `terraform/global/`
    - Configure S3 backend with DynamoDB locking in each environment `backend.tf`
    - Create `terragrunt.hcl` for DRY configuration management across environments
    - Define root `variables.tf` with mandatory tag variables (Environment, Service, Owner, CostCenter, DataClassification, Compliance)
    - _Requirements: 13.1, 13.2, 13.3, 13.5_

  - [x] 1.2 Implement AWS Organizations and multi-account structure
    - Create `terraform/global/organizations.tf` defining Organization with OUs: Security, Shared Services, Data Lake, Compute, DR
    - Define Service Control Policies (SCPs) restricting region usage and preventing public resource creation
    - Create `terraform/global/baseline_security.tf` for account-level baselines (GuardDuty, Security Hub, Config Rules, CloudTrail)
    - Parameterize modules by account ID and organizational unit for 100+ account scaling
    - _Requirements: 20.1, 20.5, 13.8_

  - [x] 1.3 Implement networking module with VPC, subnets, and Transit Gateway
    - Create `terraform/modules/networking/main.tf` with VPC (10.0.0.0/16), 6 private subnets across 3 AZs (data + compute per AZ)
    - Create `terraform/modules/networking/transit_gateway.tf` with TGW, route tables isolating prod from non-prod
    - Create `terraform/modules/networking/vpc_endpoints.tf` with Gateway (S3) and Interface endpoints (Glue, KMS, SQS, EventBridge, CloudWatch)
    - Create `terraform/modules/networking/security_groups.tf` with deny-by-default rules and explicit allow rules
    - Implement PrivateLink for API Gateway private access
    - _Requirements: 20.2, 20.3, 20.4, 20.6, 16.1_


- [x] 2. Security Baseline and IAM Foundation
  - [x] 2.1 Implement KMS encryption keys module
    - Create `terraform/modules/security/kms_keys.tf` with separate CMKs per data classification: Public, Internal, Confidential, Restricted
    - Enable automatic annual key rotation on all CMKs
    - Define key policies granting encrypt/decrypt to specific service roles only
    - Configure cross-region key replication for DR
    - _Requirements: 14.1, 2.5, 14.2_

  - [x] 2.2 Implement IAM roles and policies module
    - Create `terraform/modules/security/iam_roles.tf` with least-privilege roles: MarketDataLambdaRole, ETLGlueRole, AdvisoryAgentRole, OrderManagerRole, WalletServiceRole
    - Create `terraform/modules/security/iam_policies.tf` implementing policies from design (MARKET_DATA_LAMBDA_POLICY, ETL_GLUE_ROLE_POLICY, ADVISORY_AGENT_POLICY)
    - Implement permission boundaries constraining maximum permissions per role
    - Ensure no wildcard (*) resource permissions in any production policy
    - _Requirements: 14.3, 13.4, 20.5_

  - [x] 2.3 Implement security detection and audit services
    - Create `terraform/modules/security/guardduty.tf` with Organization-level delegation
    - Create `terraform/modules/security/security_hub.tf` enabling FSBP and CIS standards
    - Create `terraform/modules/security/cloudtrail.tf` with dedicated compliance trail stored in separate security account
    - Create `terraform/modules/security/config_rules.tf` with conformance packs for encryption, public access, and tagging compliance
    - _Requirements: 14.5, 14.6, 14.8, 20.5_


- [x] 3. Data Lake Infrastructure (S3, Glue Catalog, Lake Formation)
  - [x] 3.1 Implement S3 buckets with lifecycle and encryption
    - Create `terraform/modules/data-lake/s3_buckets.tf` with Bronze, Silver, Gold, and Regulatory Store buckets
    - Create `terraform/modules/data-lake/lifecycle.tf` with Intelligent-Tiering (Bronze: Glacier Deep Archive after 90 days; hot/warm/cold ISM for OpenSearch)
    - Create `terraform/modules/data-lake/encryption.tf` linking KMS CMKs per bucket classification
    - Enable S3 Versioning and Object Lock (Governance mode) on Bronze buckets; COMPLIANCE mode on Regulatory Store
    - Implement Hive-style partitioning structure: source=X/year=YYYY/month=MM/day=DD/hour=HH
    - _Requirements: 2.1, 2.2, 2.3, 2.5, 14.4_

  - [x] 3.2 Implement cross-region replication for DR
    - Create `terraform/modules/data-lake/replication.tf` with S3 CRR to DR region (us-west-2)
    - Configure replication for Bronze, Gold, and Terraform state buckets
    - Add replication lag monitoring with CloudWatch metrics
    - Target <15 minutes replication lag for Bronze data
    - _Requirements: 2.6, 16.3_

  - [x] 3.3 Implement Glue Data Catalog and Lake Formation
    - Create `terraform/modules/data-lake/glue_catalog.tf` with databases: verticalbroker_bronze, verticalbroker_silver, verticalbroker_gold
    - Define table schemas for market_data_raw, market_data_silver, daily_trade_summaries, client_portfolio_snapshots, instrument_performance, risk_exposure_aggregates
    - Create `terraform/modules/data-lake/lake_formation.tf` with column-level access controls per role
    - Configure Glue Crawlers for automatic partition discovery
    - _Requirements: 2.4, 3.2, 4.4, 11.1_


- [x] 4. Streaming Infrastructure (Kinesis, EventBridge, SQS)
  - [~] 4.1 Implement Kinesis Data Streams for market data ingestion
    - Create `terraform/modules/streaming/kinesis.tf` with market-data stream: 16 shards provisioned, on-demand mode enabled for burst beyond
    - Configure shard-level metrics and enhanced monitoring
    - Set data retention to 168 hours (7 days) for replay capability
    - _Requirements: 1.3_

  - [~] 4.2 Implement EventBridge event bus and rules
    - Create `terraform/modules/streaming/eventbridge.tf` with `verticalbroker-platform` event bus
    - Define schema registry entries for: data.ingested, trade.executed, pipeline.failed, compliance.alert, advisory.generated
    - Configure routing rules: data.ingested→Step Functions, trade.executed→SQS FIFO, pipeline.failed→CloudWatch, compliance.alert→SNS
    - Enable event archive for unmatched events with 30-day retention
    - _Requirements: 6.1, 6.2, 6.3, 6.6_

  - [~] 4.3 Implement SQS queues and dead-letter queues
    - Create `terraform/modules/streaming/sqs.tf` with queues: trade-processing.fifo, market-data-buffer, etl-trigger, advisory-requests, compliance-events.fifo
    - Configure DLQs for each queue with max receive count of 5 and 14-day retention
    - Set visibility timeouts per queue type (30s for trade processing, 300s for ETL triggers)
    - Configure FIFO queues with content-based deduplication for trade ordering
    - _Requirements: 6.4, 6.5, 1.4_


- [~] 5. Checkpoint - Validate foundation infrastructure
  - Ensure all Terraform modules validate (`terraform validate`), pass `tflint`, and have zero high-severity `checkov`/`tfsec` findings
  - Ensure all tests pass, ask the user if questions arise.

- [x] 6. Compute Layer: Lambda Functions, Layers, and API Gateway
  - [~] 6.1 Implement Lambda shared layer and common utilities
    - Create `src/common/` Python package with: idempotency.py (DynamoDB persistence), circuit_breaker.py (DynamoDB-backed state), retry.py (exponential backoff with jitter), dlq_handler.py, outbox.py (transactional outbox pattern)
    - Create Lambda Layer Terraform definition in `terraform/modules/compute/lambda_layers.tf` packaging shared dependencies (aws-lambda-powertools, boto3, pydantic)
    - Define Python data models in `src/models/`: market_data.py (MarketDataRaw, MarketDataSilver, DailyTradeSummaryGold), trade.py (TradeEvent, ClientProfile), events.py (EventBridge schemas)
    - _Requirements: 7.3, 7.5, 7.6, 7.7_

  - [~] 6.2 Implement Market Data Ingestion Lambda function
    - Create `src/services/market_data/handler.py` with MarketDataProcessor class
    - Implement Kinesis batch processing using Lambda Powertools BatchProcessor (100 records/batch)
    - Implement schema validation, metadata enrichment (source_id, ingestion_ts, schema_version, partition_key), and Parquet micro-batch write to S3 Bronze
    - Implement Glue Data Catalog partition registration on new partitions
    - Implement DLQ routing for malformed records and error event emission to EventBridge
    - Configure reserved concurrency: 2000, provisioned concurrency: 500
    - _Requirements: 1.1, 1.2, 1.5, 1.6, 7.1, 7.4_

  - [~] 6.3 Implement Order Manager Lambda function
    - Create `src/services/order_manager/handler.py` with OrderManager class using APIGatewayHttpResolver
    - Implement idempotent order submission using DynamoDB persistence layer (24h TTL)
    - Implement pre-trade validation (margin check, position limits, market hours)
    - Implement trade.executed event emission to EventBridge via transactional outbox pattern
    - Define routes: POST /v1/orders, GET /v1/orders/{id}
    - Configure reserved concurrency: 1000, provisioned concurrency: 200
    - _Requirements: 7.1, 7.2, 7.5, 8.4_


  - [~] 6.4 Implement Wallet Service Lambda function
    - Create `src/services/wallet/handler.py` with WalletService class
    - Implement get_portfolio (retrieve positions + cash balance from DynamoDB)
    - Implement update_position (event-driven, triggered by trade.executed events from SQS FIFO)
    - Implement check_margin (real-time margin validation for order acceptance)
    - Define routes: GET /v1/portfolio/{client_id}
    - _Requirements: 7.1, 7.2_

  - [~] 6.5 Implement Advisory Agent Lambda function
    - Create `src/services/advisory_agent/handler.py` with AdvisoryAgentService class
    - Implement get_recommendation invoking SageMaker endpoint with customer profile features
    - Implement governance rules: flag recommendations with confidence < 0.7 for human review
    - Implement FINRA compliance logging of all recommendations to Regulatory Store (S3 Object Lock COMPLIANCE mode)
    - Define routes: POST /v1/advisory
    - Configure reserved concurrency: 500, provisioned concurrency: 100
    - _Requirements: 12.1, 12.4, 12.5, 12.6_

  - [~] 6.6 Implement API Gateway and Cognito Terraform configuration
    - Create `terraform/modules/compute/api_gateway.tf` with HTTP API (REST) and WebSocket API
    - Define OpenAPI 3.0 specification with request validation for all endpoints
    - Configure rate limiting: 10K/sec authenticated, 100/sec unauthenticated
    - Implement path-based API versioning (/v1/, /v2/) with Sunset header support
    - Create `terraform/modules/compute/cognito.tf` with User Pool, JWT authorizer, and identity pool
    - Configure WebSocket endpoints for real-time market data (2h connection limit)
    - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7_

  - [~] 6.7 Implement Step Functions orchestrator
    - Create `terraform/modules/compute/step_functions.tf` defining pipeline orchestrator state machine
    - Implement state machine: ValidateInput → CheckPartition → BronzeToSilver → SilverToGold → TriggerIndexing (parallel: OpenSearch + Neptune) → EmitSuccess
    - Configure retry logic per step: Glue jobs retry 3x with 60s interval and 2.0 backoff
    - Implement error handling with catch blocks routing to EmitFailure state
    - Create `src/orchestration/pipeline_state_machine.py` with ASL definition
    - _Requirements: 6.7, 3.6_


  - [~] 6.8 Implement Lambda function Terraform definitions
    - Create `terraform/modules/compute/lambda_functions.tf` defining all Lambda functions with environment variables, VPC config, layers, and event source mappings
    - Configure Kinesis event source for MarketDataProcessor (batch size 100, parallelization factor 10)
    - Configure SQS event source for WalletService (trade-processing.fifo)
    - Configure API Gateway integrations for OrderManager, WalletService, AdvisoryAgent
    - Define DynamoDB tables: IdempotencyStore (TTL enabled), CircuitBreakerState
    - _Requirements: 7.1, 7.2, 7.3, 7.4_

- [~] 7. Checkpoint - Validate compute layer
  - Ensure all Lambda handler modules import cleanly, shared utilities have no circular dependencies
  - Ensure all Terraform compute module resources validate
  - Ensure all tests pass, ask the user if questions arise.

- [x] 8. ETL Pipelines (Glue PySpark Jobs)
  - [~] 8.1 Implement Bronze-to-Silver ETL job
    - Create `src/etl/bronze_to_silver.py` with BronzeToSilverETL class
    - Implement extract() reading from Glue Data Catalog with push-down predicate on partition_path
    - Implement validate_schema() returning (valid, rejected) DynamicFrames against catalog schema
    - Implement deduplicate() using composite key: instrument_id + timestamp + source_id
    - Implement apply_data_quality() with null checks, range validation, and freshness rules
    - Implement write_silver() outputting Parquet with Snappy compression, partitioned by instrument_type and trade_date
    - Implement write_lineage() recording input/output/rejected counts and processing metadata
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.7, 18.1, 18.2_


  - [~] 8.2 Implement Silver-to-Gold ETL job
    - Create `src/etl/silver_to_gold.py` with SilverToGoldETL class
    - Implement compute_daily_trade_summaries() with groupBy on instrument_id, trade_date computing volume, VWAP, high, low, close, trade_count
    - Implement compute_client_portfolio_snapshots() for point-in-time portfolio state per client
    - Implement compute_instrument_performance() with rolling performance metrics
    - Implement compute_risk_exposure() aggregating by client, sector, geography
    - Implement validate_referential_integrity() for cross-dataset FK validation
    - Implement incremental aggregation using CDC markers to avoid full 10 PB reprocessing
    - Output Parquet optimized for Athena partition elimination
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5_

  - [~] 8.3 Implement data quality framework
    - Create `src/etl/data_quality.py` with DataQualityEngine class
    - Implement configurable quality rules: schema conformance, null rate thresholds, range validation, freshness SLAs
    - Implement severity-based handling: HIGH → halt pipeline + emit quality.failed event; LOW → tag records + continue with quality_score metadata
    - Implement data quality scorecard metrics: completeness, accuracy, consistency, timeliness per Gold dataset
    - _Requirements: 18.1, 18.2, 18.3, 18.4, 18.5_

  - [~] 8.4 Implement Glue job Terraform definitions
    - Create `terraform/modules/data-lake/glue_jobs.tf` defining Bronze-to-Silver and Silver-to-Gold jobs
    - Configure worker type G.2X, min 10 / max 100 DPUs, auto-scaling enabled
    - Set job timeout 60 minutes, retry attempts 3, job bookmarks enabled
    - Configure Spot Instances for non-critical ETL with On-Demand fallback
    - Define Glue connections and security configuration for KMS encryption
    - _Requirements: 3.7, 4.6, 17.4_


- [x] 9. CDC Pipeline (DMS)
  - [~] 9.1 Implement DMS replication infrastructure
    - Create `terraform/modules/streaming/dms.tf` with DMS replication instance (dms.r6i.2xlarge)
    - Define source endpoint (RDS/Aurora) and target endpoint (S3 Bronze with Parquet output)
    - Configure table mappings for trading schema with all tables included
    - Enable full-load-and-cdc migration type with CDC start from current position
    - _Requirements: 5.1, 5.6_

  - [~] 9.2 Implement CDC processing and schema evolution handling
    - Create `src/services/cdc/schema_evolution.py` with CDCPipelineConfig and SchemaEvolutionHandler classes
    - Implement change capture for all DML operations (INSERT, UPDATE, DELETE) preserving before/after images
    - Implement schema evolution detection from DMS events and automatic Glue Data Catalog updates
    - Implement replication lag monitoring with alerting when lag exceeds 60 seconds
    - Emit schema.evolved events for downstream consumers
    - Configure batch_apply with batch_size 1000 for throughput
    - _Requirements: 5.2, 5.3, 5.4, 5.5_

- [~] 10. Checkpoint - Validate data pipelines
  - Ensure ETL jobs parse and validate locally with PySpark
  - Ensure DMS Terraform configurations validate
  - Ensure all tests pass, ask the user if questions arise.

- [x] 11. Analytics Services (OpenSearch, Neptune, Athena)
  - [~] 11.1 Implement OpenSearch cluster and indexing
    - Create `terraform/modules/analytics/opensearch.tf` with multi-AZ domain: 3 dedicated master nodes, 6 data nodes (r6g.2xlarge), UltraWarm enabled
    - Define index mappings for trade_records (12 shards, 2 replicas) and client_profiles (6 shards, 2 replicas)
    - Implement Index State Management policies: hot (0-30d), warm (30-90d), cold (90d-7yr), delete (>7yr)
    - Configure fine-grained access control mapped to IAM roles for PII field protection
    - Implement indexing pipeline Lambda triggered by Gold Layer S3 events
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5, 9.6_


  - [~] 11.2 Implement Neptune graph database
    - Create `terraform/modules/analytics/neptune.tf` with cluster: db.r6g.2xlarge (1 writer, 2 readers), auto-scaling at 70% CPU
    - Define subnet group within data subnets and security group allowing Gremlin (port 8182) from compute subnets only
    - Create `src/analytics/graph_model.py` with vertex/edge definitions: ClientVertex, AccountVertex, InstrumentVertex, TransactionEdge
    - Implement bulk loader integration for incremental updates every 15 minutes from Gold Layer
    - Implement fraud detection Gremlin queries: circular_transactions, rapid_transfers, unusual_velocity
    - Create graph query Lambda proxy with parameterized query templates preventing injection attacks
    - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5, 10.6_

  - [~] 11.3 Implement Athena query engine
    - Create `terraform/modules/analytics/athena.tf` with workgroups: analytics, compliance, data-science
    - Configure per-query scan limit of 1 TB and per-workgroup daily limit of 10 TB
    - Enable query result caching per workgroup
    - Define named queries for common patterns: daily trade volume, portfolio performance, risk metrics, regulatory reports
    - Implement Athena query Lambda proxy with scan estimation and limit enforcement
    - Configure independent concurrency limits and cost tracking per workgroup
    - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5, 11.6_

- [x] 12. ML Pipeline (SageMaker RL Training and Inference)
  - [~] 12.1 Implement SageMaker infrastructure
    - Create `terraform/modules/ml/sagemaker.tf` with SageMaker Domain, model package group (verticalbroker-advisory-models), and endpoint configuration
    - Configure real-time inference endpoint with A/B testing variants (production + canary)
    - Define endpoint auto-scaling policy for inference instance scaling
    - Configure Model Monitor for data drift and model quality monitoring
    - _Requirements: 12.3, 12.4, 12.7_


  - [~] 12.2 Implement SageMaker training pipeline
    - Create `src/ml/training_pipeline.py` with AdvisoryModelPipeline class
    - Implement create_feature_engineering_step() extracting features from Gold Layer historical outcomes
    - Implement create_training_step() with RLEstimator using PPO algorithm (lr=0.0003, gamma=0.99, episodes=10000, batch=256) on ml.p3.2xlarge
    - Implement create_evaluation_step() for model performance, bias detection, and fairness metrics
    - Implement create_registration_step() registering model with governance metadata (dataset version, hyperparameters, metrics, approval status)
    - Create `terraform/modules/ml/sagemaker_pipelines.tf` defining the training pipeline
    - _Requirements: 12.2, 12.3, 12.8_

  - [~] 12.3 Implement model governance and bias detection
    - Create `src/ml/model_governance.py` with ModelGovernance class
    - Implement check_bias() detecting bias across demographic groups (age, income, filing status)
    - Implement generate_explainability() using SHAP-based feature importance for regulatory transparency
    - Implement validate_fairness_metrics() ensuring equitable recommendations across protected classes
    - Implement approve_for_deployment() as final governance gate before production
    - _Requirements: 12.8, 12.5_

- [x] 13. Monitoring and Observability
  - [~] 13.1 Implement CloudWatch dashboards and alarms
    - Create `terraform/modules/monitoring/cloudwatch.tf` with dashboards: data pipeline health, API performance, cost tracking, security events, ML model performance
    - Define alarms: pipeline-latency-sla-breach, api-error-rate-above-1pct, lambda-throttling-detected, sqs-depth-above-10k, infrastructure-cpu-above-80pct, cdc-replication-lag-above-60s, kinesis-iterator-age-above-5s, glue-job-failure, cost-budget-80pct-threshold
    - Configure alarm evaluation periods to avoid flapping
    - Set up composite alarms for cascading failure detection
    - _Requirements: 15.1, 15.2, 15.4_


  - [~] 13.2 Implement alerting and notification infrastructure
    - Create `terraform/modules/monitoring/sns.tf` with notification topics for: operations (PagerDuty), security (compliance team), cost (finance team)
    - Configure alarm actions routing to appropriate SNS topics with <60 second notification delivery
    - Implement cost budget alerts at 80% threshold per service
    - Create `terraform/modules/monitoring/budgets.tf` with AWS Budget definitions per CostCenter tag
    - _Requirements: 15.3, 17.1, 17.3_

  - [~] 13.3 Implement X-Ray tracing and log management
    - Create `terraform/modules/monitoring/xray.tf` with tracing configuration: 5% sampling for normal traffic, 100% for error paths
    - Configure X-Ray integration across all Lambda functions, API Gateway, and Step Functions
    - Define CloudWatch Log Groups with 90-day retention and archive to S3 for 2-year Athena query capability
    - Implement structured logging format using Lambda Powertools Logger across all services
    - _Requirements: 15.5, 15.6_

  - [~] 13.4 Implement automated remediation runbooks
    - Create `terraform/modules/monitoring/ssm_automation.tf` with Systems Manager Automation documents
    - Implement runbooks for: restart failed pipelines, scale capacity (Glue DPUs, Lambda concurrency), rotate credentials
    - Configure alarm-triggered automation for self-healing common failure modes
    - _Requirements: 15.7_

- [~] 14. Checkpoint - Validate observability stack
  - Ensure monitoring Terraform validates and all alarm definitions reference existing resources
  - Ensure all tests pass, ask the user if questions arise.


- [x] 15. CI/CD Pipeline and Deployment Automation
  - [~] 15.1 Implement CodePipeline infrastructure
    - Define CI/CD pipeline in Terraform with stages: Source (CodeCommit/GitHub), Lint (tflint, mypy, ruff), Test (pytest), Security (checkov, tfsec, bandit), Plan (terraform plan), Approve (manual for prod), Deploy
    - Configure CodeBuild projects for each stage with appropriate IAM roles
    - Implement artifact versioning in S3 with SHA-256 integrity verification
    - Configure pipeline notifications to SNS for stage failures
    - _Requirements: 19.1, 19.2, 19.3, 19.5_

  - [~] 15.2 Implement blue-green deployment and drift detection
    - Create `deployment/blue_green.py` with BlueGreenDeployer class for Lambda alias traffic shifting
    - Implement canary deployment: 5% traffic to new version, 10-minute bake time, automatic rollback on error rate >5%
    - Implement Lambda alias management (LIVE alias) with weighted routing
    - Create daily drift detection job: terraform plan comparison against deployed state with alerts for detected drift
    - _Requirements: 19.4, 19.6_

- [x] 16. Disaster Recovery and Failover
  - [~] 16.1 Implement cross-region DR infrastructure
    - Create `terraform/environments/dr/` with pre-provisioned DR infrastructure in us-west-2
    - Deploy Lambda functions, API Gateway, and DynamoDB Global Tables in DR region
    - Configure Route 53 health checks with DNS failover (3 consecutive failures → failover)
    - Implement DynamoDB Global Tables for active-active state replication (IdempotencyStore, CircuitBreakerState)
    - _Requirements: 16.2, 16.3, 16.4_

  - [~] 16.2 Implement failover procedures and health checks
    - Implement circuit breaker patterns across all service-to-service calls to prevent cascade failures
    - Create CloudWatch Synthetics canaries for API health monitoring
    - Document automated failover procedure: DNS failover (30s) → DR Lambda active (0s) → DynamoDB active (0s) → verify CRR lag (5min) → activate DR Kinesis (30min) → start DR Glue (60min) → verify E2E (30min)
    - Configure auto-scaling policies for all compute: Lambda concurrency, Glue DPUs, Neptune readers, OpenSearch data nodes
    - _Requirements: 16.5, 16.6, 17.5_


- [x] 17. Cost Management
  - [~] 17.1 Implement cost optimization and reporting
    - Configure S3 Intelligent-Tiering lifecycle policies across the 10 PB estate with projected savings tracking
    - Configure Spot Instances for non-critical Glue ETL with On-Demand fallback (targeting 60% savings)
    - Configure reserved capacity for Neptune and OpenSearch (30-40% vs on-demand)
    - Configure Lambda Graviton2 (ARM) for all functions (20% cost + 34% performance)
    - Implement monthly cost allocation reports using AWS Cost and Usage Reports broken down by pipeline, environment, and team
    - Enable Athena query result caching for repeated analytical patterns
    - _Requirements: 17.2, 17.4, 17.5, 17.6_

- [x] 18. Data Governance and Compliance
  - [~] 18.1 Implement data masking and PII protection
    - Configure AWS Glue DataBrew for PII detection and masking in non-production environments (SSN, account numbers, DOB)
    - Implement Lake Formation column-level access controls restricting PII access by role
    - Configure Macie for automated PII discovery scans on S3 buckets
    - _Requirements: 14.7, 9.4_

  - [~] 18.2 Implement regulatory store and compliance automation
    - Configure S3 Object Lock COMPLIANCE mode on regulatory bucket with 7-year retention per FINRA 4511
    - Implement SOC 2 Type II evidence generation: automated access reviews, change management records, incident response logs
    - Configure data catalog search interface through OpenSearch for dataset discovery with quality scores and lineage
    - _Requirements: 14.4, 14.8, 18.6_

- [~] 19. Checkpoint - Full platform integration validation
  - Verify all Terraform modules compose correctly in each environment configuration
  - Verify all cross-module references (outputs → variables) are wired
  - Ensure all tests pass, ask the user if questions arise.


- [x] 20. Testing Suite
  - [~] 20.1 Implement Terraform module tests
    - Create `tests/terraform/test_data_lake_module.py` validating: S3 encryption, versioning, object lock, no wildcard IAM, mandatory tags, no public buckets, VPC endpoints configured
    - Create `tests/terraform/test_security_module.py` validating: no admin policies, permission boundaries on all roles, cross-account trust requires ExternalId, KMS rotation enabled, TLS 1.3 minimum
    - Create `tests/terraform/test_compute_module.py` validating: Lambda reserved concurrency settings, API Gateway rate limits, Cognito configuration
    - Run terraform plan output as JSON fixture for assertion-based testing
    - _Requirements: 13.7, 14.1, 14.2, 14.3_

  - [~] 20.2 Implement Lambda function unit tests
    - Create `tests/unit/test_market_data_processor.py`: valid record enrichment, malformed record DLQ routing, dedup key derivation, batch Parquet write, partition registration
    - Create `tests/unit/test_order_manager.py`: idempotent order returns cached response, margin check rejects insufficient funds, trade event emitted on execution, invalid instrument rejected
    - Create `tests/unit/test_advisory_agent.py`: low confidence flagged for review, all recommendations logged to regulatory store, model version in response, inference timeout error
    - Create `tests/unit/test_wallet_service.py`: portfolio retrieval, position update from trade event, margin check calculation
    - Use moto and pytest fixtures for AWS service mocking
    - _Requirements: 1.1, 1.5, 1.6, 7.5, 12.5, 12.6_

  - [~] 20.3 Implement ETL integration tests
    - Create `tests/integration/test_pipeline_e2e.py` using LocalStack: valid data transforms to Silver, invalid records routed to error partition, deduplication removes exact duplicates
    - Create `tests/integration/test_event_flow.py`: data.ingested triggers orchestration, pipeline.failed triggers alarm, trade.executed routes to FIFO queue
    - Create `tests/integration/test_silver_to_gold.py`: daily trade summaries computed correctly, referential integrity validated, incremental aggregation works
    - Use testcontainers with LocalStack 3.0 image
    - _Requirements: 3.2, 3.3, 4.1, 4.5, 6.3_


  - [~] 20.4 Implement security and compliance tests
    - Create `tests/security/test_iam_policies.py`: no admin access, all roles have permission boundaries, no cross-account without ExternalId
    - Create `tests/security/test_encryption.py`: all S3 KMS-encrypted, key rotation enabled, TLS 1.3 enforced
    - Create `tests/security/test_compliance.py`: regulatory store has Object Lock COMPLIANCE, CloudTrail enabled in all accounts, 7-year retention configured
    - Run checkov and tfsec as automated test stage with zero-high-severity gate
    - _Requirements: 14.1, 14.2, 14.3, 14.4, 14.5_

  - [~] 20.5 Implement monitoring and alarm validation tests
    - Create `tests/monitoring/test_alarms.py` validating: all critical alarms exist, alarm actions configured for SNS/PagerDuty, evaluation periods appropriate
    - Create `tests/monitoring/test_dashboards.py` validating: all required dashboards defined, widgets reference valid metrics
    - Verify alarm names match required set: pipeline-latency-sla-breach, api-error-rate-above-1pct, lambda-throttling-detected, sqs-depth-above-10k, etc.
    - _Requirements: 15.2, 15.3, 15.4_

- [~] 21. Final Checkpoint - Complete platform validation
  - Run full test suite: `pytest tests/ --cov --cov-report=html` targeting >80% coverage on application code
  - Run static analysis: `tflint`, `mypy src/`, `ruff check src/`
  - Run security scan: `checkov -d terraform/`, `tfsec terraform/`, `bandit -r src/`
  - Verify all 20 requirements have coverage in implementation tasks
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- All infrastructure is 100% Terraform (v1.5+ with AWS Provider 5.x) — no manual console changes
- All application code is 100% Python 3.12 with AWS Lambda Powertools
- Platform handles 100M datapoints/day (~1,157/sec avg, 12,000/sec burst) from Bloomberg B-Pipe and Thomson Reuters
- Data estate is 10 PB across Bronze/Silver/Gold medallion layers with 7-year FINRA retention
- Multi-account architecture supports 100+ AWS accounts via AWS Organizations
- Checkpoints ensure incremental validation at logical boundaries
- Each task references specific requirements for traceability
- Testing uses pytest + moto + LocalStack (no property-based testing — platform is IaC/side-effect-heavy)
- Blue-green deployment with automated rollback protects production stability


## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["1.2", "1.3"] },
    { "id": 2, "tasks": ["2.1", "2.2", "2.3"] },
    { "id": 3, "tasks": ["3.1", "3.2", "3.3", "4.1", "4.2", "4.3"] },
    { "id": 4, "tasks": ["6.1"] },
    { "id": 5, "tasks": ["6.2", "6.3", "6.4", "6.5", "6.6", "6.7"] },
    { "id": 6, "tasks": ["6.8", "8.1", "8.2", "8.3", "8.4"] },
    { "id": 7, "tasks": ["9.1", "9.2"] },
    { "id": 8, "tasks": ["11.1", "11.2", "11.3"] },
    { "id": 9, "tasks": ["12.1", "12.2", "12.3"] },
    { "id": 10, "tasks": ["13.1", "13.2", "13.3", "13.4"] },
    { "id": 11, "tasks": ["15.1", "15.2"] },
    { "id": 12, "tasks": ["16.1", "16.2", "17.1"] },
    { "id": 13, "tasks": ["18.1", "18.2"] },
    { "id": 14, "tasks": ["20.1", "20.2", "20.3", "20.4", "20.5"] }
  ]
}
```
