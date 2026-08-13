# Changelog

All notable changes to the VerticalBroker AWS Data Engineering Platform will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Production-readiness tooling (CI/CD, Docker, testing, build scripts)
- Comprehensive unit test suite (28 test files, ~200+ test cases)
- Integration tests with moto/LocalStack mocks
- GitHub Actions CI/CD pipelines (ci, deploy-dev, deploy-prod, terraform-plan)
- Docker development environment (LocalStack + PostgreSQL)
- Makefile with 22 development commands
- Ruff + Black + Mypy code quality configuration
- Pre-commit hooks for automated quality gates
- Build scripts for Lambda packaging (ARM64/Graviton2)
- Terraform validation and security scanning (TFLint, Checkov)
- CONTRIBUTING.md developer guide

## [1.0.0] - 2024-01-15

### Added

- Complete AWS infrastructure (69 Terraform files, 8 modules)
  - Networking: VPC, Transit Gateway, VPC Endpoints, Security Groups
  - Security: KMS (4 CMKs), IAM (5 roles, no wildcards), GuardDuty, SecurityHub
  - Data Lake: S3 Medallion (Bronze/Silver/Gold), Glue Catalog, Lake Formation
  - Streaming: Kinesis (16 shards), EventBridge, SQS FIFO, DMS CDC
  - Compute: Lambda (7 functions), API Gateway, Cognito, Step Functions, DynamoDB
  - Analytics: OpenSearch, Neptune, Athena
  - ML: SageMaker Domain, Endpoints (A/B), Pipelines
  - Monitoring: CloudWatch (9 alarms, 3 composite), SNS, X-Ray, SSM Automation

- Python application code (37 files)
  - Market Data Processor (Kinesis → S3 Bronze Parquet)
  - Order Manager (API GW → DynamoDB, idempotent, transactional outbox)
  - Wallet Service (Portfolio, margin validation, SQS FIFO consumer)
  - Advisory Agent (SageMaker RL inference, FINRA compliance logging)
  - CDC Handler (Schema evolution detection)
  - Common utilities (idempotency, circuit breaker, retry, DLQ, outbox)
  - ETL: Bronze→Silver→Gold (PySpark, dedup, data quality)
  - ML: Training pipeline (PPO RL), Model governance (bias, fairness, SHAP)
  - Analytics: Neptune graph model (fraud detection)
  - Orchestration: Step Functions state machine (7 states)

- Architecture diagrams (8 draw.io files)
- Comprehensive README with scale calculations and interview guides
- Multi-environment Terraform configuration (dev/staging/production/dr)

### Security

- FINRA 4511 compliance: 7-year immutable retention (S3 Object Lock COMPLIANCE)
- KMS CMKs per data classification (Public/Internal/Confidential/Restricted)
- IAM least-privilege (no wildcard resources)
- Lake Formation column-level PII security
- GuardDuty threat detection + SecurityHub FSBP/CIS
- CloudTrail data events for full audit trail

---

## Version History Format

### Types of changes

- **Added** for new features
- **Changed** for changes in existing functionality
- **Deprecated** for soon-to-be removed features
- **Removed** for now removed features
- **Fixed** for bug fixes
- **Security** for vulnerability fixes
