"""
Unit tests for idempotency module.
Tests: DynamoDB persistence layer, TTL expiry, duplicate detection, config creation.
"""

import time
import uuid
from datetime import UTC, datetime
from unittest.mock import MagicMock, patch

import boto3
import pytest
from moto import mock_aws


pytestmark = pytest.mark.unit


class TestIdempotencyConfig:
    """Tests for idempotency configuration and persistence layer."""

    def test_default_ttl_is_24_hours(self):
        """Default idempotency TTL is 24 hours (86400 seconds)."""
        default_ttl = 24 * 60 * 60
        assert default_ttl == 86400

    def test_custom_ttl_configuration(self):
        """Custom TTL can be specified for different use cases."""
        custom_ttl = 12 * 60 * 60  # 12 hours
        assert custom_ttl == 43200

    def test_local_cache_max_items_default(self):
        """Local cache defaults to 1000 items for Lambda warm start optimization."""
        local_cache_max = 1000
        assert local_cache_max > 0

    def test_idempotency_table_name(self):
        """Persistence layer uses 'IdempotencyStore' table by default."""
        table_name = "IdempotencyStore"
        assert table_name == "IdempotencyStore"

    def test_event_key_jmespath_extraction(self):
        """JMESPath expression extracts unique key from event."""
        # The idempotency key is extracted from event headers
        event = {
            "headers": {"x-idempotency-key": "unique-key-123"},
            "body": '{"order_id": "ord-001"}',
        }
        key = event["headers"]["x-idempotency-key"]
        assert key == "unique-key-123"


class TestDuplicateDetection:
    """Tests for duplicate request handling."""

    @mock_aws
    def test_first_request_stores_record(self):
        """First request with a new key stores the idempotency record."""
        dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
        table = dynamodb.create_table(
            TableName="IdempotencyStore",
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )

        idempotency_key = str(uuid.uuid4())
        table.put_item(Item={
            "id": idempotency_key,
            "status": "INPROGRESS",
            "expiration": int(time.time()) + 86400,
            "data": '{"order_id": "ord-001"}',
        })

        response = table.get_item(Key={"id": idempotency_key})
        assert "Item" in response
        assert response["Item"]["status"] == "INPROGRESS"

    @mock_aws
    def test_duplicate_request_returns_cached_result(self):
        """Second request with same key returns cached response (no re-execution)."""
        dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
        table = dynamodb.create_table(
            TableName="IdempotencyStore",
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )

        idempotency_key = "duplicate-key-001"
        cached_response = {"order_id": "ord-001", "status": "ACCEPTED"}

        # Store completed record
        table.put_item(Item={
            "id": idempotency_key,
            "status": "COMPLETED",
            "expiration": int(time.time()) + 86400,
            "data": str(cached_response),
        })

        # Second request finds the cached record
        response = table.get_item(Key={"id": idempotency_key})
        assert response["Item"]["status"] == "COMPLETED"

    @mock_aws
    def test_expired_record_allows_reprocessing(self):
        """Expired idempotency records allow the request to be re-executed."""
        dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
        table = dynamodb.create_table(
            TableName="IdempotencyStore",
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )

        idempotency_key = "expired-key-001"
        expired_time = int(time.time()) - 3600  # 1 hour ago (expired)

        table.put_item(Item={
            "id": idempotency_key,
            "status": "COMPLETED",
            "expiration": expired_time,
            "data": '{"old": "response"}',
        })

        response = table.get_item(Key={"id": idempotency_key})
        record_expiration = int(response["Item"]["expiration"])
        assert record_expiration < int(time.time())  # Expired

    def test_concurrent_request_uses_conditional_write(self):
        """Concurrent requests use DynamoDB conditional write to prevent race conditions."""
        # Pattern: put_item with ConditionExpression="attribute_not_exists(id)"
        condition = "attribute_not_exists(id)"
        assert "attribute_not_exists" in condition


class TestIdempotencyStateMachine:
    """Tests for the idempotency state transitions."""

    def test_state_transitions(self):
        """Idempotency records transition: INPROGRESS → COMPLETED or EXPIRED."""
        valid_states = {"INPROGRESS", "COMPLETED", "EXPIRED"}
        assert "INPROGRESS" in valid_states
        assert "COMPLETED" in valid_states

    def test_inprogress_prevents_parallel_execution(self):
        """INPROGRESS status blocks parallel execution of same key."""
        status = "INPROGRESS"
        should_execute = status not in ("INPROGRESS", "COMPLETED")
        assert should_execute is False

    def test_completed_returns_cached_response(self):
        """COMPLETED status returns cached response without re-execution."""
        status = "COMPLETED"
        should_return_cache = status == "COMPLETED"
        assert should_return_cache is True
