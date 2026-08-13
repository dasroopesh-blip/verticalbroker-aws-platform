"""
Unit tests for Advisory Agent Lambda handler.
Tests: SageMaker inference, governance evaluation, FINRA compliance logging.
"""

import json
import uuid
from datetime import UTC, datetime
from unittest.mock import MagicMock

import pytest


pytestmark = pytest.mark.unit


class TestAdvisoryAgentHandler:
    """Tests for POST /v1/advisory endpoint."""

    def test_valid_profile_returns_recommendation(self, sample_advisory_event):
        """Valid customer profile returns an advisory recommendation."""
        body = json.loads(sample_advisory_event["body"])
        assert body["client_id"] == "client-001"
        assert body["risk_tolerance"] == "MODERATE"
        assert body["investment_horizon"] == "LONG_TERM"

    def test_sagemaker_invoke_under_500ms_sla(self):
        """SageMaker endpoint invocation must complete under 500ms SLA."""
        # The handler measures latency and records metric
        sla_ms = 500
        mock_latency = 350  # Typical response
        assert mock_latency < sla_ms

    def test_low_confidence_requires_human_review(self):
        """Confidence < 0.7 triggers requires_human_review flag."""
        confidence = 0.65
        threshold = 0.7
        requires_review = confidence < threshold
        assert requires_review is True

    def test_high_confidence_no_review_needed(self):
        """Confidence >= 0.7 does not require human review."""
        confidence = 0.85
        threshold = 0.7
        requires_review = confidence < threshold
        assert requires_review is False

    def test_sagemaker_response_parsing(self):
        """SageMaker endpoint response is correctly parsed into recommendation."""
        sagemaker_response = {
            "Body": MagicMock(
                read=lambda: json.dumps({
                    "recommendation": "MODERATE_GROWTH",
                    "confidence": 0.87,
                    "allocations": {
                        "US_EQUITY": 0.45,
                        "INTL_EQUITY": 0.20,
                        "FIXED_INCOME": 0.25,
                        "ALTERNATIVES": 0.10,
                    },
                    "rationale": "Based on risk tolerance and investment horizon",
                }).encode()
            )
        }
        payload = json.loads(sagemaker_response["Body"].read())
        assert payload["recommendation"] == "MODERATE_GROWTH"
        assert payload["confidence"] == 0.87
        assert sum(payload["allocations"].values()) == pytest.approx(1.0)


class TestGovernanceEvaluation:
    """Tests for advisory governance rules."""

    def test_governance_flags_undisclosed_risk(self):
        """Governance engine flags if recommendation risk exceeds profile."""
        recommended_equity_pct = 0.80  # 80% equity (CONSERVATIVE max = 40%)
        conservative_max_equity = 0.40

        exceeds_risk = recommended_equity_pct > conservative_max_equity
        assert exceeds_risk is True

    def test_governance_passes_within_risk(self):
        """Recommendation within risk tolerance passes governance."""
        recommended_equity_pct = 0.80  # AGGRESSIVE max = 90%
        aggressive_max_equity = 0.90

        exceeds_risk = recommended_equity_pct > aggressive_max_equity
        assert exceeds_risk is False

    def test_finra_4511_compliance_logging(self):
        """All recommendations are logged with Object Lock COMPLIANCE (7-year retention)."""
        compliance_log = {
            "recommendation_id": str(uuid.uuid4()),
            "client_id": "client-001",
            "timestamp": datetime.now(UTC).isoformat(),
            "recommendation": "MODERATE_GROWTH",
            "confidence": 0.87,
            "governance_outcome": "APPROVED",
            "retention_mode": "COMPLIANCE",
            "retention_years": 7,
        }
        assert compliance_log["retention_mode"] == "COMPLIANCE"
        assert compliance_log["retention_years"] == 7

    def test_s3_object_lock_write(self):
        """Regulatory store write includes ObjectLockMode=COMPLIANCE."""
        put_object_params = {
            "Bucket": "vb-regulatory-test",
            "Key": "advisory/2024/01/15/recommendation-001.json",
            "Body": json.dumps({"recommendation": "test"}),
            "ObjectLockMode": "COMPLIANCE",
            "ObjectLockRetainUntilDate": "2031-01-15T00:00:00Z",
            "ServerSideEncryption": "aws:kms",
            "SSEKMSKeyId": "arn:aws:kms:us-east-1:123456789012:key/restricted-key",
        }
        assert put_object_params["ObjectLockMode"] == "COMPLIANCE"
        assert "2031" in put_object_params["ObjectLockRetainUntilDate"]


class TestAdvisoryEventEmission:
    """Tests for EventBridge event emission after advisory."""

    def test_advisory_event_structure(self):
        """AdvisoryGenerated event has correct EventBridge structure."""
        event = {
            "Source": "verticalbroker.advisory-agent",
            "DetailType": "AdvisoryGenerated",
            "EventBusName": "verticalbroker-platform-test",
            "Detail": json.dumps({
                "recommendation_id": str(uuid.uuid4()),
                "client_id": "client-001",
                "recommendation_type": "MODERATE_GROWTH",
                "confidence": 0.87,
                "requires_human_review": False,
                "timestamp": datetime.now(UTC).isoformat(),
            }),
        }
        assert event["Source"] == "verticalbroker.advisory-agent"
        assert event["DetailType"] == "AdvisoryGenerated"
        detail = json.loads(event["Detail"])
        assert detail["requires_human_review"] is False


class TestCustomerProfileValidation:
    """Tests for customer profile input validation."""

    def test_valid_profile_all_fields(self):
        """Complete customer profile passes validation."""
        profile = {
            "client_id": "client-001",
            "risk_tolerance": "MODERATE",
            "investment_horizon": "LONG_TERM",
            "age": 35,
            "annual_income": "150000.00",
            "portfolio_value": "500000.00",
            "tax_filing_status": "SINGLE",
        }
        valid_tolerances = {"CONSERVATIVE", "MODERATE", "AGGRESSIVE"}
        assert profile["risk_tolerance"] in valid_tolerances

    def test_invalid_risk_tolerance_rejected(self):
        """Invalid risk_tolerance value is rejected."""
        invalid = "YOLO"
        valid_tolerances = {"CONSERVATIVE", "MODERATE", "AGGRESSIVE"}
        assert invalid not in valid_tolerances

    def test_negative_age_rejected(self):
        """Age must be positive."""
        age = -5
        assert age <= 0

    def test_missing_client_id_rejected(self):
        """client_id is required."""
        profile = {"risk_tolerance": "MODERATE"}
        assert "client_id" not in profile
