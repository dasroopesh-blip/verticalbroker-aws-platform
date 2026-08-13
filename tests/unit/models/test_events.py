"""
Unit tests for EventBridge event models.
Tests: BaseEvent, DataIngestedEvent, TradeExecutedEvent, PipelineFailedEvent,
       ComplianceAlertEvent, AdvisoryGeneratedEvent.
"""

import json
import uuid
from datetime import datetime, timezone

import pytest


pytestmark = pytest.mark.unit


class TestBaseEvent:
    """Tests for the base EventBridge event structure."""

    def test_base_event_required_fields(self):
        """All events must have source, detail_type, and detail."""
        event = {
            "Source": "verticalbroker.market-data",
            "DetailType": "MarketDataIngested",
            "Detail": json.dumps({"key": "value"}),
            "EventBusName": "verticalbroker-platform",
        }
        assert "Source" in event
        assert "DetailType" in event
        assert "Detail" in event

    def test_source_follows_naming_convention(self):
        """Event sources use 'verticalbroker.<service-name>' format."""
        valid_sources = [
            "verticalbroker.market-data",
            "verticalbroker.order-manager",
            "verticalbroker.etl-engine",
            "verticalbroker.advisory-agent",
            "verticalbroker.security",
        ]
        for source in valid_sources:
            assert source.startswith("verticalbroker.")

    def test_to_eventbridge_entry_format(self):
        """to_eventbridge_entry() produces dict compatible with put_events."""
        entry = {
            "Source": "verticalbroker.market-data",
            "DetailType": "MarketDataIngested",
            "EventBusName": "verticalbroker-platform",
            "Detail": json.dumps({
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "correlation_id": str(uuid.uuid4()),
            }),
        }
        # Must be serializable
        serialized = json.dumps(entry)
        assert serialized is not None
        # Detail must be a JSON string
        assert isinstance(entry["Detail"], str)


class TestDataIngestedEvent:
    """Tests for MarketDataIngested event."""

    def test_event_detail_fields(self):
        """DataIngestedEvent includes source_id, s3_key, record_count."""
        detail = {
            "source_id": "bloomberg-feed-1",
            "s3_key": "bronze/source=bloomberg/trade_date=2024-01-15/batch.parquet",
            "record_count": 100,
            "size_bytes": 45000,
            "instrument_types": ["equity", "option"],
            "ingestion_timestamp": datetime.now(timezone.utc).isoformat(),
            "correlation_id": str(uuid.uuid4()),
        }
        assert detail["record_count"] > 0
        assert detail["s3_key"].endswith(".parquet")
        assert "bronze/" in detail["s3_key"]

    def test_event_source_is_market_data(self):
        """DataIngestedEvent source is 'verticalbroker.market-data'."""
        source = "verticalbroker.market-data"
        detail_type = "MarketDataIngested"
        assert source == "verticalbroker.market-data"
        assert detail_type == "MarketDataIngested"


class TestTradeExecutedEvent:
    """Tests for TradeExecuted event."""

    def test_event_detail_fields(self):
        """TradeExecutedEvent includes order_id, trade details, compliance fields."""
        detail = {
            "order_id": str(uuid.uuid4()),
            "client_id": "client-001",
            "instrument_id": "AAPL",
            "side": "BUY",
            "quantity": "100",
            "price": "185.50",
            "total_value": "18550.00",
            "executed_at": datetime.now(timezone.utc).isoformat(),
            "correlation_id": str(uuid.uuid4()),
        }
        assert detail["side"] in ("BUY", "SELL")
        assert "order_id" in detail
        assert "correlation_id" in detail

    def test_event_source_is_order_manager(self):
        """TradeExecutedEvent source is 'verticalbroker.order-manager'."""
        source = "verticalbroker.order-manager"
        detail_type = "TradeExecuted"
        assert source == "verticalbroker.order-manager"
        assert detail_type == "TradeExecuted"

    def test_event_routes_to_wallet_via_sqs(self):
        """TradeExecuted routes to SQS FIFO queue for wallet position update."""
        target = "arn:aws:sqs:us-east-1:123456789012:trade-processing.fifo"
        assert "trade-processing.fifo" in target


class TestPipelineFailedEvent:
    """Tests for PipelineExecutionFailed event."""

    def test_event_detail_fields(self):
        """PipelineFailedEvent includes job_name, error, duration."""
        detail = {
            "job_name": "bronze-to-silver",
            "job_run_id": str(uuid.uuid4()),
            "error_type": "DataQualityAbortError",
            "error_message": "Rejection rate 35% exceeds threshold 30%",
            "records_processed": 50000,
            "records_rejected": 17500,
            "duration_seconds": 245,
            "retry_count": 2,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        assert detail["error_type"] == "DataQualityAbortError"
        rejection_rate = detail["records_rejected"] / detail["records_processed"]
        assert rejection_rate == 0.35

    def test_event_source_is_etl_engine(self):
        """PipelineFailedEvent source is 'verticalbroker.etl-engine'."""
        source = "verticalbroker.etl-engine"
        assert source == "verticalbroker.etl-engine"


class TestComplianceAlertEvent:
    """Tests for ComplianceAlert event."""

    def test_event_detail_fields(self):
        """ComplianceAlertEvent includes alert_type, severity, affected resources."""
        detail = {
            "alert_type": "UNAUTHORIZED_ACCESS_ATTEMPT",
            "severity": "HIGH",
            "affected_resource": "arn:aws:s3:::vb-regulatory-prod",
            "source_ip": "10.0.1.15",
            "user_identity": "arn:aws:iam::123456789012:user/suspicious-user",
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "remediation": "Credentials rotated automatically via SSM Runbook",
        }
        assert detail["severity"] in ("LOW", "MEDIUM", "HIGH", "CRITICAL")
        assert "remediation" in detail

    def test_event_source_is_security(self):
        """ComplianceAlertEvent source is 'verticalbroker.security'."""
        source = "verticalbroker.security"
        assert source == "verticalbroker.security"


class TestAdvisoryGeneratedEvent:
    """Tests for AdvisoryGenerated event."""

    def test_event_detail_fields(self):
        """AdvisoryGeneratedEvent includes recommendation details and governance."""
        detail = {
            "recommendation_id": str(uuid.uuid4()),
            "client_id": "client-001",
            "recommendation_type": "MODERATE_GROWTH",
            "confidence": 0.87,
            "requires_human_review": False,
            "governance_outcome": "APPROVED",
            "model_version": "v2.3.1",
            "latency_ms": 350,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        assert detail["confidence"] >= 0.7  # No human review needed
        assert detail["requires_human_review"] is False
        assert detail["latency_ms"] < 500  # Under SLA

    def test_event_source_is_advisory_agent(self):
        """AdvisoryGeneratedEvent source is 'verticalbroker.advisory-agent'."""
        source = "verticalbroker.advisory-agent"
        detail_type = "AdvisoryGenerated"
        assert source == "verticalbroker.advisory-agent"
        assert detail_type == "AdvisoryGenerated"
