# Contributing to VerticalBroker Platform

## Quick Start

```bash
# 1. Clone and install
git clone https://github.com/dasroopesh-blip/verticalbroker-aws-platform.git
cd verticalbroker-aws-platform
make install

# 2. Start local infrastructure
make docker-up

# 3. Seed test data
make seed-data

# 4. Run tests
make test

# 5. Check code quality
make lint
```

## Development Workflow

### Branch Strategy

| Branch | Purpose | Deploys To |
|--------|---------|------------|
| `main` | Production-ready code | Dev (auto) → Staging (manual) → Prod (release) |
| `feature/*` | New features | PR → CI runs → review → merge |
| `fix/*` | Bug fixes | PR → CI runs → review → merge |
| `hotfix/*` | Production emergency fixes | PR → fast-track review → merge → release |

### Making Changes

1. **Create a branch** from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Write code** following our conventions (see below).

3. **Run checks locally** before pushing:
   ```bash
   make lint        # Ruff + Black + Mypy
   make test-unit   # Fast unit tests
   make security    # Bandit + Safety
   ```

4. **Push and open a PR**:
   ```bash
   git push origin feature/your-feature-name
   ```

5. **CI runs automatically** — lint, test, security scan, Terraform validate.

6. **Get review** — at least 1 approval required.

7. **Merge** — squash merge to `main`.

## Code Conventions

### Python

- **Version**: Python 3.12
- **Formatter**: Black (120 char line length)
- **Linter**: Ruff (see `ruff.toml`)
- **Types**: Use type hints on all public functions
- **Money**: Always use `Decimal`, never `float`
- **Dates**: Always timezone-aware (`datetime.now(timezone.utc)`)
- **No print()**: Use `aws_lambda_powertools.Logger` instead
- **No wildcard imports**: Explicit imports only

### Lambda Handlers

```python
# Standard Lambda handler pattern
from aws_lambda_powertools import Logger, Metrics, Tracer

logger = Logger()
tracer = Tracer()
metrics = Metrics()

@logger.inject_lambda_context
@tracer.capture_lambda_handler
@metrics.log_metrics
def lambda_handler(event, context):
    ...
```

### Terraform

- **Format**: `terraform fmt` (enforced by CI)
- **Variables**: All variables must have `description` and `type`
- **No wildcards**: IAM policies must use specific resource ARNs
- **Tags**: All resources must have `Project`, `Environment`, `ManagedBy` tags
- **Naming**: `snake_case` for resources, `kebab-case` for names

### Testing

- **Unit tests**: Fast, no external dependencies, use `moto` for AWS mocking
- **Integration tests**: Use LocalStack or full moto mocks
- **Markers**: Use `@pytest.mark.unit`, `@pytest.mark.integration`, `@pytest.mark.etl`
- **Coverage**: Minimum 80% line coverage

## Project Structure (New Files)

```
# Where to add new code:
src/services/<service_name>/       # New Lambda handlers
src/common/                        # Shared utilities
src/models/                        # Shared data models
src/etl/                           # New Glue PySpark jobs
terraform/modules/<module_name>/   # New Terraform modules

# Where to add tests:
tests/unit/services/               # Lambda handler unit tests
tests/unit/common/                 # Utility unit tests
tests/unit/etl/                    # PySpark unit tests
tests/integration/                 # End-to-end integration tests
```

## Local Development

### Prerequisites

- Python 3.12+
- Docker & Docker Compose
- Terraform 1.5+ (for infrastructure work)
- AWS CLI v2 (for deployment scripts)

### Local Stack

```bash
make docker-up    # Start LocalStack + PostgreSQL
make docker-down  # Stop everything
make docker-logs  # View logs
```

**Available local services:**
- **LocalStack** (`localhost:4566`): S3, DynamoDB, SQS, Kinesis, EventBridge
- **PostgreSQL** (`localhost:5432`): Aurora substitute (user: `vb_admin`, pass: `local_dev_only`)

### Running Specific Tests

```bash
make test-unit     # All unit tests
make test-integ    # Integration tests
make test-etl      # PySpark/ETL tests only
make test-ml       # ML pipeline tests only
make coverage      # Full coverage report → htmlcov/index.html
```

## Deployment

### Dev (automatic on merge to main)

CI automatically deploys to dev on merge. See `.github/workflows/deploy-dev.yml`.

### Production (manual release)

1. Create a GitHub Release with a version tag (e.g., `v1.2.0`)
2. Production workflow triggers with manual approval gate
3. Review Terraform plan output in PR comment
4. Approve in GitHub Environments settings
5. Monitor CloudWatch dashboards post-deploy

### Manual deployment commands

```bash
# Build packages
make package                    # Local build
make package-docker             # Docker build (ARM64/Graviton2)

# Terraform
make tf-plan ENV=dev            # Plan for dev
make tf-apply ENV=production    # Apply to production (with confirmation)

# Glue scripts
make deploy-glue ENV=staging    # Deploy ETL scripts
```

## Security Guidelines

- **No hardcoded secrets** — use AWS Secrets Manager or SSM Parameter Store
- **No PII in logs** — use Powertools Logger with `@logger.inject_lambda_context`
- **KMS encryption** — all data at rest uses appropriate KMS CMK per classification
- **IAM least-privilege** — no wildcard `Resource: "*"` in policies
- **Dependency scanning** — `safety check` runs in CI

## Questions?

Open an issue or reach out to the platform team.
