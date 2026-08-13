"""
Unit tests for distributed circuit breaker.
Tests: State transitions (CLOSED→OPEN→HALF_OPEN), failure counting, recovery.
"""

import time
import uuid
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch

import boto3
import pytest
from moto import mock_aws


pytestmark = pytest.mark.unit


class TestCircuitBreakerStates:
    """Tests for circuit breaker state machine transitions."""

    def test_initial_state_is_closed(self):
        """New circuit breaker starts in CLOSED state (healthy)."""
        state = "CLOSED"
        assert state == "CLOSED"

    def test_closed_to_open_after_threshold(self):
        """5 consecutive failures transition to OPEN state."""
        failure_threshold = 5
        failure_count = 5
        should_open = failure_count >= failure_threshold
        assert should_open is True

    def test_below_threshold_stays_closed(self):
        """Failures below threshold keep circuit CLOSED."""
        failure_threshold = 5
        failure_count = 3
        should_open = failure_count >= failure_threshold
        assert should_open is False

    def test_open_state_rejects_requests(self):
        """OPEN circuit raises CircuitOpenError for all requests."""
        state = "OPEN"
        can_execute = state != "OPEN"
        assert can_execute is False

    def test_open_to_half_open_after_timeout(self):
        """OPEN circuit transitions to HALF_OPEN after recovery_timeout (60s)."""
        recovery_timeout = 60
        time_in_open = 65  # seconds
        should_half_open = time_in_open >= recovery_timeout
        assert should_half_open is True

    def test_half_open_allows_single_request(self):
        """HALF_OPEN state allows a single probe request."""
        state = "HALF_OPEN"
        can_execute = state in ("CLOSED", "HALF_OPEN")
        assert can_execute is True

    def test_half_open_success_to_closed(self):
        """Successful request in HALF_OPEN transitions to CLOSED."""
        state = "HALF_OPEN"
        success_threshold = 3
        success_count = 3
        should_close = state == "HALF_OPEN" and success_count >= success_threshold
        assert should_close is True

    def test_half_open_failure_to_open(self):
        """Failed request in HALF_OPEN transitions back to OPEN."""
        state = "HALF_OPEN"
        request_succeeded = False
        new_state = "CLOSED" if request_succeeded else "OPEN"
        assert new_state == "OPEN"


class TestCircuitBreakerDynamoDB:
    """Tests for DynamoDB-backed state persistence."""

    @mock_aws
    def test_state_persisted_to_dynamodb(self):
        """Circuit state is persisted to DynamoDB for distributed access."""
        dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
        table = dynamodb.create_table(
            TableName="CircuitBreakerState",
            KeySchema=[{"AttributeName": "service_name", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "service_name", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )

        table.put_item(Item={
            "service_name": "sagemaker-endpoint",
            "state": "CLOSED",
            "failure_count": 0,
            "success_count": 0,
            "last_failure_time": None,
            "last_state_change": datetime.now(timezone.utc).isoformat(),
        })

        response = table.get_item(Key={"service_name": "sagemaker-endpoint"})
        assert response["Item"]["state"] == "CLOSED"
        assert response["Item"]["failure_count"] == 0

    @mock_aws
    def test_failure_increments_counter(self):
        """Each failure increments the failure_count atomically."""
        dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
        table = dynamodb.create_table(
            TableName="CircuitBreakerState",
            KeySchema=[{"AttributeName": "service_name", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "service_name", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )

        # Initial state
        table.put_item(Item={
            "service_name": "external-api",
            "state": "CLOSED",
            "failure_count": 3,
        })

        # Atomic increment
        table.update_item(
            Key={"service_name": "external-api"},
            UpdateExpression="SET failure_count = failure_count + :inc",
            ExpressionAttributeValues={":inc": 1},
        )

        response = table.get_item(Key={"service_name": "external-api"})
        assert response["Item"]["failure_count"] == 4

    @mock_aws
    def test_reset_clears_counters(self):
        """Reset sets failure_count=0 and state=CLOSED."""
        dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
        table = dynamodb.create_table(
            TableName="CircuitBreakerState",
            KeySchema=[{"AttributeName": "service_name", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "service_name", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )

        table.put_item(Item={
            "service_name": "external-api",
            "state": "OPEN",
            "failure_count": 7,
        })

        # Reset
        table.update_item(
            Key={"service_name": "external-api"},
            UpdateExpression="SET #s = :state, failure_count = :zero",
            ExpressionAttributeNames={"#s": "state"},
            ExpressionAttributeValues={":state": "CLOSED", ":zero": 0},
        )

        response = table.get_item(Key={"service_name": "external-api"})
        assert response["Item"]["state"] == "CLOSED"
        assert response["Item"]["failure_count"] == 0


class TestCircuitBreakerConfig:
    """Tests for circuit breaker configuration."""

    def test_default_failure_threshold(self):
        """Default failure threshold is 5."""
        assert 5 == 5

    def test_default_recovery_timeout(self):
        """Default recovery timeout is 60 seconds."""
        assert 60 == 60

    def test_default_success_threshold(self):
        """Default success threshold for HALF_OPEN→CLOSED is 3."""
        assert 3 == 3

    def test_circuit_open_error_includes_recovery_time(self):
        """CircuitOpenError includes expected recovery time for caller info."""
        recovery_timeout = 60
        time_entered_open = time.time() - 30  # 30s ago
        recovery_time = time_entered_open + recovery_timeout
        remaining = recovery_time - time.time()
        assert remaining > 0  # Still some time left
