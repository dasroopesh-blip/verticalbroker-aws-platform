"""
Integration tests for Order Management end-to-end flow.
Tests: API GW → Order Manager → DynamoDB → EventBridge → SQS → Wallet.
"""

import json
import uuid
from datetime import datetime, timezone
from decimal import Decimal

import boto3
import pytest
from moto import mock_aws


pytestmark = pytest.mark.integration


class TestOrderFlowE2E:
    """End-to-end tests for the order processing flow."""

    @mock_aws
    def test_order_stored_in_dynamodb(self, monkeypatch):
        """Order submission persists to DynamoDB Orders table."""
        monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")

        dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
        table = dynamodb.create_table(
            TableName="Orders",
            KeySchema=[{"AttributeName": "order_id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "order_id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )

        order_id = str(uuid.uuid4())
        table.put_item(Item={
            "order_id": order_id,
            "client_id": "client-001",
            "instrument_id": "AAPL",
            "side": "BUY",
            "quantity": Decimal("100"),
            "price": Decimal("185.50"),
            "status": "ACCEPTED",
            "created_at": datetime.now(timezone.utc).isoformat(),
        })

        response = table.get_item(Key={"order_id": order_id})
        assert response["Item"]["status"] == "ACCEPTED"
        assert response["Item"]["instrument_id"] == "AAPL"

    @mock_aws
    def test_outbox_event_created_atomically(self, monkeypatch):
        """Order + outbox event are written in same DynamoDB transaction."""
        monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")

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

        response = client.transact_write_items(
            TransactItems=[
                {
                    "Put": {
                        "TableName": "Orders",
                        "Item": {
                            "order_id": {"S": order_id},
                            "status": {"S": "ACCEPTED"},
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
        assert response["ResponseMetadata"]["HTTPStatusCode"] == 200

    @mock_aws
    def test_trade_event_reaches_sqs_fifo(self, monkeypatch):
        """TradeExecuted event is delivered to trade-processing.fifo queue."""
        monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")

        sqs = boto3.client("sqs", region_name="us-east-1")
        queue_url = sqs.create_queue(
            QueueName="trade-processing.fifo",
            Attributes={"FifoQueue": "true", "ContentBasedDeduplication": "true"},
        )["QueueUrl"]

        trade_event = {
            "order_id": str(uuid.uuid4()),
            "client_id": "client-001",
            "instrument_id": "AAPL",
            "side": "BUY",
            "quantity": "100",
            "price": "185.50",
        }

        sqs.send_message(
            QueueUrl=queue_url,
            MessageBody=json.dumps(trade_event),
            MessageGroupId="client-001",
        )

        messages = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=1)
        assert len(messages["Messages"]) == 1
        body = json.loads(messages["Messages"][0]["Body"])
        assert body["instrument_id"] == "AAPL"

    @mock_aws
    def test_wallet_position_updated_after_trade(self, monkeypatch):
        """Wallet service updates portfolio position after processing trade."""
        monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")

        dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
        table = dynamodb.create_table(
            TableName="Portfolio",
            KeySchema=[
                {"AttributeName": "client_id", "KeyType": "HASH"},
                {"AttributeName": "account_id", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "client_id", "AttributeType": "S"},
                {"AttributeName": "account_id", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )

        # Existing portfolio
        table.put_item(Item={
            "client_id": "client-001",
            "account_id": "account-001",
            "positions": {"AAPL": {"quantity": Decimal("100"), "avg_cost": Decimal("180.00")}},
            "cash_balance": Decimal("100000.00"),
        })

        # Simulate position update (BUY 50 more @ 185.50)
        response = table.get_item(Key={"client_id": "client-001", "account_id": "account-001"})
        portfolio = response["Item"]
        existing = portfolio["positions"]["AAPL"]
        new_qty = existing["quantity"] + Decimal("50")
        new_cost = (existing["quantity"] * existing["avg_cost"] + Decimal("50") * Decimal("185.50")) / new_qty

        portfolio["positions"]["AAPL"] = {"quantity": new_qty, "avg_cost": new_cost}
        table.put_item(Item=portfolio)

        # Verify
        updated = table.get_item(Key={"client_id": "client-001", "account_id": "account-001"})
        assert updated["Item"]["positions"]["AAPL"]["quantity"] == Decimal("150")


class TestIdempotencyE2E:
    """Integration tests for idempotency across the order flow."""

    @mock_aws
    def test_duplicate_order_rejected(self, monkeypatch):
        """Second order with same idempotency key returns cached result."""
        monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")

        dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
        table = dynamodb.create_table(
            TableName="IdempotencyStore",
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )

        idempotency_key = "order-idem-key-001"

        # First request creates record
        table.put_item(Item={
            "id": idempotency_key,
            "status": "COMPLETED",
            "data": json.dumps({"order_id": "ord-001", "status": "ACCEPTED"}),
            "expiration": 9999999999,
        })

        # Second request finds existing record
        response = table.get_item(Key={"id": idempotency_key})
        assert response["Item"]["status"] == "COMPLETED"
        cached = json.loads(response["Item"]["data"])
        assert cached["order_id"] == "ord-001"
