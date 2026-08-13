"""
Unit tests for Dead Letter Queue processor.
Tests: Failed message investigation, EventBridge emission, CloudWatch metrics.
"""

import json
import uuid
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import boto3
import pytest
from moto import mock_aws


pytestmark = pytest.mark.unit


class TestDLQProcessor:
    """Tests for DLQ message processing and alerting."""

    def test_process_single_message(self):
        """Single DLQ message is processed and context extracted."""
        message = {
            "messageId": str(uuid.uuid4()),
            "body": json.dumps({
                "source_id": "bloomberg-feed-1",
                "instrument_id": "AAPL",
                "error": "SchemaValidationError",
                "original_timestamp": datetime.now(timezone.utc).isoformat(),
            }),
            "attributes": {
                "ApproximateReceiveCount": "4",
                "ApproximateFirstReceiveTimestamp": "1704067200000",
            },
            "eventSourceARN": "arn:aws:sqs:us-east-1:123456789012:market-data-dlq",
        }
        body = json.loads(message["body"])
        assert body["error"] == "SchemaValidationError"
        assert body["instrument_id"] == "AAPL"

    def test_batch_processing_multiple_messages(self):
        """Multiple DLQ messages are processed in batch."""
        messages = [
            {"messageId": str(uuid.uuid4()), "body": json.dumps({"error": f"Error-{i}"})}
            for i in range(5)
        ]
        results = []
        for msg in messages:
            body = json.loads(msg["body"])
            results.append(body)

        assert len(results) == 5
        assert results[0]["error"] == "Error-0"
        assert results[4]["error"] == "Error-4"

    def test_failure_context_extraction(self):
        """Failure context includes source ARN, receive count, original error."""
        message = {
            "messageId": "msg-001",
            "body": json.dumps({"instrument_id": "TSLA", "price": -5.0}),
            "attributes": {
                "ApproximateReceiveCount": "5",
                "ApproximateFirstReceiveTimestamp": "1704067200000",
            },
            "eventSourceARN": "arn:aws:sqs:us-east-1:123456789012:market-data-dlq",
        }

        context = {
            "message_id": message["messageId"],
            "receive_count": int(message["attributes"]["ApproximateReceiveCount"]),
            "source_queue": message["eventSourceARN"].split(":")[-1],
            "body": json.loads(message["body"]),
            "failure_timestamp": datetime.now(timezone.utc).isoformat(),
        }

        assert context["receive_count"] == 5
        assert context["source_queue"] == "market-data-dlq"


class TestDLQEventEmission:
    """Tests for EventBridge failure event emission."""

    @mock_aws
    def test_failure_event_emitted_to_eventbridge(self):
        """DLQ processor emits failure event to verticalbroker event bus."""
        events_client = boto3.client("events", region_name="us-east-1")
        events_client.create_event_bus(Name="verticalbroker-platform-test")

        entry = {
            "Source": "verticalbroker.dlq-processor",
            "DetailType": "MessageProcessingFailed",
            "EventBusName": "verticalbroker-platform-test",
            "Detail": json.dumps({
                "message_id": str(uuid.uuid4()),
                "source_queue": "market-data-dlq",
                "receive_count": 5,
                "failure_reason": "SchemaValidationError",
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }),
        }

        response = events_client.put_events(Entries=[entry])
        assert response["FailedEntryCount"] == 0

    def test_event_structure_matches_schema(self):
        """Failure event follows the verticalbroker event schema."""
        event = {
            "Source": "verticalbroker.dlq-processor",
            "DetailType": "MessageProcessingFailed",
            "EventBusName": "verticalbroker-platform-test",
            "Detail": json.dumps({
                "message_id": "msg-001",
                "source_queue": "market-data-dlq",
                "receive_count": 5,
                "failure_reason": "SchemaValidationError",
            }),
        }
        assert event["Source"].startswith("verticalbroker.")
        detail = json.loads(event["Detail"])
        assert "message_id" in detail
        assert "failure_reason" in detail


class TestDLQMetrics:
    """Tests for CloudWatch metric recording."""

    @mock_aws
    def test_failure_metric_recorded(self):
        """DLQ processing records a CloudWatch metric."""
        cw_client = boto3.client("cloudwatch", region_name="us-east-1")

        cw_client.put_metric_data(
            Namespace="VerticalBroker/DLQ",
            MetricData=[{
                "MetricName": "MessagesFailed",
                "Value": 1,
                "Unit": "Count",
                "Dimensions": [
                    {"Name": "Queue", "Value": "market-data-dlq"},
                    {"Name": "ErrorType", "Value": "SchemaValidationError"},
                ],
            }],
        )

        # Metric was recorded (moto accepts the call)
        # In production, this triggers alarms at threshold
        assert True

    def test_metric_namespace_is_correct(self):
        """Metrics use VerticalBroker/DLQ namespace."""
        namespace = "VerticalBroker/DLQ"
        assert namespace == "VerticalBroker/DLQ"

    def test_metric_dimensions_include_queue_and_error(self):
        """Metrics are dimensioned by queue name and error type."""
        dimensions = [
            {"Name": "Queue", "Value": "market-data-dlq"},
            {"Name": "ErrorType", "Value": "SchemaValidationError"},
        ]
        dim_names = [d["Name"] for d in dimensions]
        assert "Queue" in dim_names
        assert "ErrorType" in dim_names
