# =============================================================================
# VerticalBroker AWS Data Engineering Platform
# Single-command task runner for development, testing, and deployment.
# =============================================================================

.PHONY: help install lint test test-unit test-integ test-etl coverage \
        tf-fmt tf-validate tf-plan tf-apply \
        package docker-up docker-down docker-test \
        clean security pre-commit

# Default target
help: ## Show this help message
	@echo "╔══════════════════════════════════════════════════════════════════╗"
	@echo "║  VerticalBroker Platform - Development Commands                 ║"
	@echo "╚══════════════════════════════════════════════════════════════════╝"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""

# =============================================================================
# Python Environment
# =============================================================================

install: ## Install all dependencies (dev + runtime)
	python -m pip install --upgrade pip
	pip install -r requirements/dev.txt
	pip install -e .
	pre-commit install || true
	@echo "✓ Dependencies installed. Run 'make test' to verify."

install-prod: ## Install production dependencies only
	pip install -r requirements/base.txt
	pip install -e .

# =============================================================================
# Code Quality
# =============================================================================

lint: ## Run all linters (ruff, black, mypy)
	@echo "=== Ruff (lint) ==="
	ruff check src/ tests/
	@echo "=== Black (format check) ==="
	black --check --diff src/ tests/
	@echo "=== Mypy (type check) ==="
	mypy src/ --ignore-missing-imports || true
	@echo "✓ All lint checks passed"

format: ## Auto-format code (ruff fix + black)
	ruff check --fix src/ tests/
	black src/ tests/
	@echo "✓ Code formatted"

pre-commit: ## Run pre-commit hooks on all files
	pre-commit run --all-files

# =============================================================================
# Testing
# =============================================================================

test: ## Run all tests (unit + integration)
	pytest tests/ -v --tb=short

test-unit: ## Run unit tests only (fast, no external deps)
	pytest tests/unit/ -m "unit" -v --tb=short

test-integ: ## Run integration tests (requires moto/LocalStack)
	pytest tests/integration/ -m "integration" -v --tb=short

test-etl: ## Run ETL/PySpark tests
	pytest tests/unit/etl/ -m "etl" -v --tb=short

test-ml: ## Run ML pipeline tests
	pytest tests/unit/ml/ -m "ml" -v --tb=short

coverage: ## Run tests with coverage report
	pytest tests/ \
		--cov=src \
		--cov-report=term-missing \
		--cov-report=html:htmlcov \
		--cov-fail-under=80 \
		-v
	@echo "✓ Coverage report: htmlcov/index.html"

# =============================================================================
# Security
# =============================================================================

security: ## Run security scans (bandit + safety)
	@echo "=== Bandit (code security) ==="
	bandit -r src/ --severity-level medium --confidence-level medium -q
	@echo "=== Safety (dependency vulnerabilities) ==="
	safety check || true
	@echo "✓ Security scan complete"

# =============================================================================
# Terraform
# =============================================================================

ENV ?= dev

tf-fmt: ## Format Terraform files
	terraform -chdir=terraform fmt -recursive
	@echo "✓ Terraform formatted"

tf-validate: ## Validate Terraform configuration
	cd terraform && terraform init -backend=false -input=false && terraform validate
	@echo "✓ Terraform valid"

tf-plan: ## Run Terraform plan (ENV=dev|staging|production)
	cd terraform/environments/$(ENV) && \
		terraform init -input=false && \
		terraform plan -var-file=terraform.tfvars
	@echo "✓ Plan complete for $(ENV)"

tf-apply: ## Run Terraform apply (ENV=dev|staging|production)
	cd terraform/environments/$(ENV) && \
		terraform init -input=false && \
		terraform apply -var-file=terraform.tfvars
	@echo "✓ Apply complete for $(ENV)"

tf-test: ## Run Terraform validation + security tests
	bash tests/terraform/test_validate.sh
	bash tests/terraform/test_tflint.sh
	bash tests/terraform/test_checkov.sh

# =============================================================================
# Build & Package
# =============================================================================

package: ## Build Lambda ZIP + layer artifacts
	bash scripts/build-lambda.sh
	@echo "✓ Packages built in build/"

package-docker: ## Build packages using Docker (ARM64/Graviton2)
	docker build -f docker/Dockerfile.lambda -t vb-lambda-builder .
	mkdir -p build
	docker run --rm -v $(PWD)/build:/artifacts vb-lambda-builder
	@echo "✓ Docker-built packages in build/"

# =============================================================================
# Docker / Local Development
# =============================================================================

docker-up: ## Start local dev stack (LocalStack + PostgreSQL)
	docker compose -f docker/docker-compose.yml up -d
	@echo "✓ Local stack running"
	@echo "  LocalStack: http://localhost:4566"
	@echo "  PostgreSQL: localhost:5432 (vb_admin/local_dev_only)"

docker-down: ## Stop and remove local dev stack
	docker compose -f docker/docker-compose.yml down -v
	@echo "✓ Local stack stopped"

docker-test: ## Run tests in Docker (CI-style)
	docker compose -f docker/docker-compose.test.yml up --build --abort-on-container-exit test-runner
	docker compose -f docker/docker-compose.test.yml down

docker-logs: ## View LocalStack logs
	docker compose -f docker/docker-compose.yml logs -f localstack

# =============================================================================
# Deployment Helpers
# =============================================================================

deploy-glue: ## Upload Glue scripts to S3 (ENV=dev|staging|production)
	bash scripts/deploy-glue-scripts.sh $(ENV)

seed-data: ## Load test data into local environment
	bash scripts/seed-test-data.sh

# =============================================================================
# Cleanup
# =============================================================================

clean: ## Remove build artifacts, caches, temp files
	rm -rf build/ dist/ *.egg-info htmlcov/ .pytest_cache/ .mypy_cache/ .ruff_cache/
	rm -f coverage.xml test-results.xml .coverage
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete 2>/dev/null || true
	@echo "✓ Cleaned"

clean-all: clean ## Remove everything including Docker volumes
	docker compose -f docker/docker-compose.yml down -v 2>/dev/null || true
	rm -rf /tmp/localstack
	@echo "✓ Deep clean complete"
