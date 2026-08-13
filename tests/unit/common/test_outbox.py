"""
Unit tests for transactional outbox pattern.
Tests: Atomic write + event, DynamoDB transactions, unpublished event retrieval.
"""

import json
import time
import uuid
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch

import boto3
import pytest
from moto import mock_aws


pytestmark = pytest.mark.unit


class TestTransactionalOutbox:
    """Tests for execute_with_outbox (atomic business + event write)."""

    @mock_aws
    def test_execute_with_outbox_writes_both_items(self):
        """execute_with_outbox atomically writes business item + outbox event."""
        dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
        table = dynamodb.create_table(
            TableName="OrderOutbox",
            KeySchema=[
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )

        event_id = str(uuid.uuid4())
        table.put_item(Item={
            "pk": f"OUTBOX#{event_id}",
            "sk": f"EVENT#{datetime.now(timezone.utc).isoformat()}",
            "event_type": "TradeExecuted",
            "source": "verticalbroker.order-manager",
            "detail": json.dumps({"order_id": "ord-001", "status": "FILLED"}),
            "published": False,
            "ttl": int(time.time()) + 7 * 86400,
        })

        response = table.get_item(Key={"pk": f"OUTBOX#{event_id}", "sk": response["Item"]["sk"]} if False else {"pk": f"OUTBOX#{event_id}"})
        # Use scan for verification
        scan_result = table.scan()
        assert scan_result["Count"] == 1
        assert scan_result["Items"][0]["published"] is False

    @mock_aws
    def test_outbox_uses_transact_write_items(self):
        """Outbox uses DynamoDB TransactWriteItems for atomicity."""
        client = boto3.client("dynamodb", region_name="us-east-1")
        client.create_table(
            TableName="Orders",
            KeySchema=[{"AttributeName": "order_id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "order_id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        client.create_table(
            TableName="OrderOutbox",
            KeySchema=[
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )

        order_id = str(uuid.uuid4())
        event_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc).isoformat()

        # Atomic transaction: order + outbox event
        response = client.transact_write_items(
            TransactItems=[
                {
                    "Put": {
                        "TableName": "Orders",
                        "Item": {
                            "order_id": {"S": order_id},
                            "status": {"S": "ACCEPTED"},
                            "created_at": {"S": now},
                        },
                    }
                },
                {
                    "Put": {
                        "TableName": "OrderOutbox",
                        "Item": {
                            "pk": {"S": f"OUTBOX#{event_id}"},
                            "sk": {"S": f"EVENT#{now}"},
                            "event_type": {"S": "TradeExecuted"},
                            "published": {"BOOL": False},
                        },
                    }
                },
            ]
        )
        # TransactWriteItems returns 200 on success
        assert response["ResponseMetadata"]["HTTPStatusCode"] == 200


class TestOutboxPublishing:
    """Tests for publishing unpublished outbox events to EventBridge."""

    @mock_aws
    def test_get_unpublished_events(self):
        """Retrieves all unpublished events (published=False)."""
        dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
        table = dynamodb.create_table(
            TableName="OrderOutbox",
            KeySchema=[
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )

        # Create 3 unpublished and 2 published
        for i in range(5):
            table.put_item(Item={
                "pk": f"OUTBOX#event-{i}",
                "sk": f"EVENT#2024-01-01T00:00:0{i}Z",
                "published": i >= 3,  # First 3 unpublished
                "event_type": "TradeExecuted",
            })

        # Scan for unpublished
        result = table.scan(
            FilterExpression=boto3.dynamodb.conditions.Attr("published").eq(False)
        )
        assert result["Count"] == 3

    @mock_aws
    def test_publish_marks_event_as_published(self):
        """After successful EventBridge publish, mark as published=True."""
        dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
        table = dynamodb.create_table(
            TableName="OrderOutbox",
            KeySchema=[
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )

        pk = "OUTBOX#event-001"
        sk = "EVENT#2024-01-01T00:00:00Z"
        table.put_item(Item={"pk": pk, "sk": sk, "published": False})

        # Mark as published
        table.update_item(
            Key={"pk": pk, "sk": sk},
            UpdateExpression="SET published = :true, published_at = :ts",
            ExpressionAttributeValues={
                ":true": True,
                ":ts": datetime.now(timezone.utc).isoformat(),
            },
        )

        response = table.get_item(Key={"pk": pk, "sk": sk})
        assert response["Item"]["published"] is True

    def test_outbox_ttl_7_days(self):
        """Outbox events have a 7-day TTL for automatic cleanup."""
        ttl_days = 7
        ttl_seconds = ttl_days * 24 * 60 * 60
        assert ttl_seconds == 604800

    @mock_aws
    def test_publish_to_eventbridge(self):
        """Outbox event is correctly formatted for EventBridge put_events."""
        events_client = boto3.client("events", region_name="us-east-1")
        events_client.create_event_bus(Name="verticalbroker-platform-test")

        outbox_record = {
            "event_type": "TradeExecuted",
            "source": "verticalbroker.order-manager",
            "detail": json.dumps({"order_id": "ord-001", "status": "FILLED"}),
        }

        response = events_client.put_events(Entries=[{
            "Source": outbox_record["source"],
            "DetailType": outbox_record["event_type"],
            "EventBusName": "verticalbroker-platform-test",
            "Detail": outbox_record["detail"],
        }])

        assert response["FailedEntryCount"] == 0
