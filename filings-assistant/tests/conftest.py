"""Shared pytest fixtures. Forces fully-offline mode for all tests."""

from __future__ import annotations

import os

os.environ.setdefault("FA_RUN_MODE", "local")
os.environ.setdefault("FA_USE_MOCK_BEDROCK", "true")

import pytest

from filings_assistant.common.config import Settings


@pytest.fixture
def settings() -> Settings:
    return Settings(
        run_mode="local",
        use_mock_bedrock=True,
        embedding_dimensions=64,
        enable_reranking=True,
    )
