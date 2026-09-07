"""Central configuration for filings-assistant.

All settings load from environment variables (prefix ``FA_``) with safe
defaults, so the whole system runs locally with zero setup and switches to
real AWS by flipping a few env vars. See ``.env.example`` for the full list.
"""

from __future__ import annotations

from enum import Enum
from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class RunMode(str, Enum):
    """Where the system runs its dependencies."""

    LOCAL = "local"  # docker-compose OpenSearch/Postgres, mock Bedrock/SEC allowed
    AWS = "aws"  # real Bedrock, OpenSearch Service, RDS, SQS


class Settings(BaseSettings):
    """Application settings, populated from the environment.

    Notes:
        - Model IDs are configuration, not hardcoded, so a new Claude/Titan
          version is a one-line env change (IDs also vary by AWS region).
        - ``use_mock_bedrock`` lets the full pipeline run offline using a
          deterministic fake embedder + templated answerer.
    """

    model_config = SettingsConfigDict(env_prefix="FA_", env_file=".env", extra="ignore")

    run_mode: RunMode = RunMode.LOCAL

    # AWS / Bedrock ---------------------------------------------------------
    aws_region: str = Field(default="us-east-1", alias="AWS_REGION")
    bedrock_reasoning_model_id: str = "anthropic.claude-3-5-sonnet-20240620-v1:0"
    bedrock_embedding_model_id: str = "amazon.titan-embed-text-v2:0"
    embedding_dimensions: int = 1024
    use_mock_bedrock: bool = True

    # OpenSearch ------------------------------------------------------------
    opensearch_host: str = "localhost"
    opensearch_port: int = 9200
    opensearch_use_ssl: bool = False
    opensearch_index: str = "sec-filings"
    opensearch_user: str = "admin"
    opensearch_password: str = "admin"

    # Postgres (source of truth) -------------------------------------------
    pg_host: str = "localhost"
    pg_port: int = 5432
    pg_db: str = "filings"
    pg_user: str = "fa_admin"
    pg_password: str = "local_dev_only"

    # Queue -----------------------------------------------------------------
    queue_url: str = ""

    # SEC EDGAR -------------------------------------------------------------
    sec_user_agent: str = "filings-assistant/0.1 (contact: you@example.com)"

    # Retrieval / chunking --------------------------------------------------
    chunk_size_tokens: int = 800
    chunk_overlap_tokens: int = 120
    top_k: int = 6
    # Number of candidates the reranker re-scores (the shortlist size).
    rerank_candidates: int = 50

    # Multi-tenancy ---------------------------------------------------------
    # "bridge" = shared cluster, index-per-tenant (default). "silo" = separate
    # infra per tenant (deploy-time). App code uses per-tenant names either way.
    tenancy_model: str = "bridge"
    # Fallback tenant for local/dev single-tenant use. Production resolves the
    # tenant from the auth token, never from this default.
    default_tenant_id: str = "default"

    # Reranking / SageMaker -------------------------------------------------
    # If set (aws mode), the reranker calls this SageMaker endpoint. Empty =>
    # use the local cross-encoder fallback.
    sagemaker_reranker_endpoint: str = ""
    enable_reranking: bool = True

    @property
    def pg_dsn(self) -> str:
        """Return a libpq connection string for psycopg."""
        return (
            f"host={self.pg_host} port={self.pg_port} dbname={self.pg_db} "
            f"user={self.pg_user} password={self.pg_password}"
        )


@lru_cache
def get_settings() -> Settings:
    """Return a cached Settings instance (read env once per process)."""
    return Settings()
