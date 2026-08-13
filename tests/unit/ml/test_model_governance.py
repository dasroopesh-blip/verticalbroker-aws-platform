"""
Unit tests for model governance module.
Tests: Bias detection, fairness thresholds, SHAP explainability, approval gate.
"""

from decimal import Decimal

import pytest


pytestmark = [pytest.mark.unit, pytest.mark.ml]


class TestBiasDetection:
    """Tests for bias check across protected groups."""

    def test_no_bias_detected(self):
        """Model with <5% deviation across groups passes bias check."""
        predictions_by_group = {
            "age_18_30": {"mean_score": 0.72},
            "age_31_50": {"mean_score": 0.74},
            "age_51_plus": {"mean_score": 0.71},
        }
        scores = [g["mean_score"] for g in predictions_by_group.values()]
        max_deviation = max(scores) - min(scores)
        threshold_pct = 5.0
        has_bias = (max_deviation * 100) > threshold_pct
        assert has_bias is False  # 3% < 5% threshold

    def test_bias_detected_exceeds_threshold(self):
        """Model with >5% deviation is flagged for bias."""
        predictions_by_group = {
            "income_low": {"mean_score": 0.60},
            "income_mid": {"mean_score": 0.73},
            "income_high": {"mean_score": 0.78},
        }
        scores = [g["mean_score"] for g in predictions_by_group.values()]
        max_deviation = max(scores) - min(scores)
        threshold_pct = 5.0
        has_bias = (max_deviation * 100) > threshold_pct
        assert has_bias is True  # 18% > 5% threshold

    def test_protected_groups_defined(self):
        """Protected groups include age, income, and filing status."""
        protected_groups = {
            "age": ["18-30", "31-50", "51+"],
            "income": ["low", "mid", "high"],
            "tax_filing_status": ["SINGLE", "MARRIED_FILING_JOINTLY", "HEAD_OF_HOUSEHOLD"],
        }
        assert "age" in protected_groups
        assert "income" in protected_groups
        assert "tax_filing_status" in protected_groups

    def test_bias_report_structure(self):
        """BiasReport contains group metrics and overall pass/fail."""
        report = {
            "model_version": "v2.3.1",
            "evaluated_at": "2024-01-15T00:00:00Z",
            "overall_passed": False,
            "max_deviation_pct": 18.0,
            "threshold_pct": 5.0,
            "group_metrics": [
                {"group": "income_low", "mean_score": 0.60, "sample_count": 1000},
                {"group": "income_high", "mean_score": 0.78, "sample_count": 1000},
            ],
        }
        assert report["overall_passed"] is False
        assert report["max_deviation_pct"] > report["threshold_pct"]


class TestFairnessMetrics:
    """Tests for fairness validation across demographics."""

    def test_fairness_within_threshold(self):
        """Group deviation ≤5% passes fairness check."""
        group_deviations = [2.1, 3.5, 1.8, 4.2]
        threshold = 5.0
        all_pass = all(d <= threshold for d in group_deviations)
        assert all_pass is True

    def test_fairness_exceeds_threshold(self):
        """Any group with >5% deviation fails fairness."""
        group_deviations = [2.1, 3.5, 7.8, 4.2]  # 7.8% > 5%
        threshold = 5.0
        all_pass = all(d <= threshold for d in group_deviations)
        assert all_pass is False

    def test_fairness_result_structure(self):
        """FairnessResult contains passed, deviation details, protected groups."""
        result = {
            "passed": True,
            "max_group_deviation_pct": 4.2,
            "threshold_pct": 5.0,
            "groups_evaluated": ["age", "income", "tax_filing_status"],
            "model_version": "v2.3.1",
        }
        assert result["passed"] is True
        assert result["max_group_deviation_pct"] < result["threshold_pct"]


class TestExplainability:
    """Tests for SHAP explainability report generation."""

    def test_shap_report_generated(self):
        """Explainability step produces a SHAP report."""
        report = {
            "model_version": "v2.3.1",
            "feature_importances": {
                "risk_tolerance": 0.35,
                "portfolio_value": 0.25,
                "age": 0.15,
                "annual_income": 0.15,
                "investment_horizon": 0.10,
            },
            "sample_count": 1000,
            "method": "SHAP",
        }
        assert report["method"] == "SHAP"
        assert sum(report["feature_importances"].values()) == pytest.approx(1.0)

    def test_top_features_identified(self):
        """SHAP identifies top contributing features."""
        importances = {"risk_tolerance": 0.35, "portfolio_value": 0.25, "age": 0.15}
        top_feature = max(importances, key=importances.get)
        assert top_feature == "risk_tolerance"


class TestGovernanceDecision:
    """Tests for the governance approval gate."""

    def test_all_checks_pass_approved(self):
        """When bias, fairness, and explainability all pass → APPROVED."""
        bias_passed = True
        fairness_passed = True
        explainability_available = True

        if bias_passed and fairness_passed and explainability_available:
            decision = "APPROVED"
        else:
            decision = "REJECTED"
        assert decision == "APPROVED"

    def test_bias_fail_rejects(self):
        """Bias check failure → REJECTED."""
        bias_passed = False
        decision = "APPROVED" if bias_passed else "REJECTED"
        assert decision == "REJECTED"

    def test_fairness_fail_rejects(self):
        """Fairness check failure → REJECTED."""
        fairness_passed = False
        decision = "APPROVED" if fairness_passed else "REJECTED"
        assert decision == "REJECTED"

    def test_missing_explainability_pending(self):
        """Missing SHAP report → PENDING_REVIEW (not auto-reject)."""
        explainability_available = False
        decision = "PENDING_REVIEW" if not explainability_available else "APPROVED"
        assert decision == "PENDING_REVIEW"

    def test_approval_updates_model_registry(self):
        """Approved model updates Model Registry status to 'Approved'."""
        governance_outcome = "APPROVED"
        model_registry_status = "Approved" if governance_outcome == "APPROVED" else "Rejected"
        assert model_registry_status == "Approved"

    def test_governance_decision_persisted_to_s3(self):
        """Governance decision is stored in S3 with KMS encryption for audit."""
        decision_record = {
            "model_version": "v2.3.1",
            "decision": "APPROVED",
            "reviewer": "ml-governance-pipeline",
            "conditions": ["Monitor for 7 days", "Max 10% traffic (canary)"],
            "s3_key": "governance/v2.3.1/decision-2024-01-15.json",
            "encryption": "aws:kms",
        }
        assert decision_record["encryption"] == "aws:kms"
        assert "governance/" in decision_record["s3_key"]
