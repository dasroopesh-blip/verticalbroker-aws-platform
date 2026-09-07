"""Unit tests for IR evaluation metrics."""

from __future__ import annotations

import pytest

from filings_assistant.evaluation.metrics import aggregate, ndcg_at_k, recall_at_k, reciprocal_rank

pytestmark = pytest.mark.unit


def test_recall_at_k() -> None:
    ranked = ["a", "b", "c", "d"]
    relevant = {"b", "d", "z"}
    # 2 of 3 relevant found in top 4.
    assert recall_at_k(ranked, relevant, 4) == pytest.approx(2 / 3)
    # only "b" in top 2.
    assert recall_at_k(ranked, relevant, 2) == pytest.approx(1 / 3)


def test_reciprocal_rank() -> None:
    assert reciprocal_rank(["a", "b", "c"], {"b"}) == pytest.approx(0.5)
    assert reciprocal_rank(["a", "b"], {"z"}) == 0.0


def test_ndcg_perfect_vs_worse() -> None:
    relevant = {"a", "b"}
    perfect = ndcg_at_k(["a", "b", "c"], relevant, 3)
    worse = ndcg_at_k(["c", "a", "b"], relevant, 3)
    assert perfect == pytest.approx(1.0)
    assert worse < perfect


def test_aggregate_averages() -> None:
    per_query = [{"mrr": 1.0}, {"mrr": 0.0}]
    assert aggregate(per_query)["mrr"] == pytest.approx(0.5)
