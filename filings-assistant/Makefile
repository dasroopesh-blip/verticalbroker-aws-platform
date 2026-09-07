# filings-assistant — developer commands
# Mirrors the VerticalBroker Makefile ergonomics.
.DEFAULT_GOAL := help
.PHONY: help install lint fmt test docker-up docker-down ingest ask tf-init tf-plan tf-apply tf-destroy

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	 awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

install: ## Install package + dev deps into current environment
	pip install -e ".[dev,mcp]"

lint: ## Run ruff + black --check + mypy
	ruff check src tests
	black --check src tests
	mypy src

fmt: ## Auto-format with black + ruff --fix
	black src tests
	ruff check --fix src tests

test: ## Run unit tests
	pytest -m unit

docker-up: ## Start local OpenSearch + Postgres ($0 dev)
	docker compose -f docker/docker-compose.yml up -d

docker-down: ## Stop local stack
	docker compose -f docker/docker-compose.yml down

ingest: ## Ingest filings, e.g. make ingest ARGS="--ticker AAPL --form 10-K --limit 1"
	python -m filings_assistant.ingestion.cli $(ARGS)

ask: ## Ask the agent a question, e.g. make ask Q="What risks does AAPL cite about supply chain?"
	python -m filings_assistant.agent.cli "$(Q)"

# --- Terraform (dev) -------------------------------------------------------
tf-init: ## terraform init
	cd terraform && terraform init

tf-plan: ## terraform plan (dev)
	cd terraform && terraform plan -var-file=environments/dev.tfvars

tf-apply: ## terraform apply (dev)
	cd terraform && terraform apply -var-file=environments/dev.tfvars

tf-destroy: ## Tear everything down so you stop paying for idle infra
	cd terraform && terraform destroy -var-file=environments/dev.tfvars
