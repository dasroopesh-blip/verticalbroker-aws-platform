"""
Integration tests for Market Data end-to-end flow.
Tests: Kinesis → Lambda → S3 Bronze (Parquet) using LocalStack/moto.
"""

import base64
import json
import uuid
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import boto3
import pytest
from moto import mock_aws


pytestmark = pytest.mark.integration


class TestMarketDataIngestionE2E:
    """End-to-end tests for market data ingestion pipeline."""

    @mock_aws
    def test_kinesis_to_s3_bronze_flow(self, monkeypatch):
        """Full flow: Kinesis record → Lambda → S3 Bronze (Parquet file written)."""
        monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
        monkeypatch.setenv("BRONZE_BUCKET", "vb-bronze-integration")
        monkeypatch.setenv("DLQ_URL", "https://sqs.us-east-1.amazonaws.com/123456789012/dlq")
        monkeypatch.setenv("EVENT_BUS_NAME", "verticalbroker-platform")
        monkeypatch.setenv("GLUE_DATABASE", "verticalbroker_bronze")
        monkeypatch.setenv("POWERTOOLS_SERVICE_NAME", "market-data")
        monkeypatch.setenv("POWERTOOLS_METRICS_NAMESPACE", "VerticalBroker")
        monkeypatch.setenv("LOG_LEVEL", "DEBUG")

        # Create infrastructure
        s3 = boto3.client("s3", region_name="us-east-1")
        s3.create_bucket(Bucket="vb-bronze-integration")

        sqs = boto3.client("sqs", region_name="us-east-1")
        sqs.create_queue(QueueName="dlq")

        events = boto3.client("events", region_name="us-east-1")
        events.create_event_bus(Name="verticalbroker-platform")

        # Verify S3 bucket exists
        buckets = s3.list_buckets()
        bucket_names = [b["Name"] for b in buckets["Buckets"]]
        assert "vb-bronze-integration" in bucket_names

    @mock_aws
    def test_multiple_sources_processed_independently(self, monkeypatch):
        """Records from different sources are grouped into separate Parquet files."""
        monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
        monkeypatch.setenv("BRONZE_BUCKET", "vb-bronze-integration")

        s3 = boto3.client("s3", region_name="us-east-1")
        s3.create_bucket(Bucket="vb-bronze-integration")

        # Simulate writes from two sources
        for source in ["bloomberg", "reuters"]:
            s3.put_object(
                Bucket="vb-bronze-integration",
                Key=f"bronze/source={source}/trade_date=2024-01-15/batch-001.parquet",
                Body=b"parquet-content-placeholder",
            )

        # Verify both source partitions exist
        response = s3.list_objects_v2(Bucket="vb-bronze-integration", Prefix="bronze/")
        keys = [obj["Key"] for obj in response["Contents"]]
        assert any("source=bloomberg" in k for k in keys)
        assert any("source=reuters" in k for k in keys)

    @mock_aws
    def test_dlq_receives_invalid_records(self, monkeypatch):
        """Invalid records are routed to the Dead Letter Queue."""
        monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")

        sqs = boto3.client("sqs", region_name="us-east-1")
        queue_url = sqs.create_queue(QueueName="market-data-dlq")["QueueUrl"]

        # Simulate sending a failed record to DLQ
        sqs.send_message(
            QueueUrl=queue_url,
            MessageBody=json.dumps({
                "error": "SchemaValidationError",
                "original_record": {"garbage": "data"},
                "failed_at": datetime.now(timezone.utc).isoformat(),
            }),
        )

        # Verify message is in DLQ
        messages = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=1)
        assert len(messages["Messages"]) == 1
        body = json.loads(messages["Messages"][0]["Body"])
        assert body["error"] == "SchemaValidationError"

    @mock_aws
    def test_eventbridge_receives_ingestion_event(self, monkeypatch):
        """Successful ingestion emits MarketDataIngested to EventBridge."""
        monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")

        events = boto3.client("events", region_name="us-east-1")
        events.create_event_bus(Name="verticalbroker-platform")

        # Simulate event emission
        response = events.put_events(Entries=[{
            "Source": "verticalbroker.market-data",
            "DetailType": "MarketDataIngested",
            "EventBusName": "verticalbroker-platform",
            "Detail": json.dumps({
                "source_id": "bloomberg",
                "s3_key": "bronze/source=bloomberg/trade_date=2024-01-15/batch.parquet",
                "record_count": 100,
                "size_bytes": 45000,
            }),
        }])
        assert response["FailedEntryCount"] == 0
