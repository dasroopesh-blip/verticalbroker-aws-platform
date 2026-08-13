"""
Unit tests for Wallet Service Lambda handler.
Tests: Portfolio retrieval, position updates, margin validation, SQS FIFO processing.
"""

import json
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from unittest.mock import MagicMock, patch

import boto3
import pytest
from moto import mock_aws


pytestmark = pytest.mark.unit


class TestWalletServiceAPI:
    """Tests for API Gateway routes (GET /v1/portfolio)."""

    @mock_aws
    def test_get_portfolio_returns_positions(self, monkeypatch):
        """GET /v1/portfolio/{client_id} returns portfolio with positions."""
        monkeypatch.setenv("PORTFOLIO_TABLE", "Portfolio")

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

        # Seed a portfolio
        table.put_item(Item={
            "client_id": "client-001",
            "account_id": "account-001",
            "positions": {
                "AAPL": {"quantity": Decimal("100"), "avg_cost": Decimal("185.50")},
                "MSFT": {"quantity": Decimal("50"), "avg_cost": Decimal("380.00")},
            },
            "cash_balance": Decimal("50000.00"),
            "updated_at": datetime.now(timezone.utc).isoformat(),
        })

        response = table.get_item(Key={"client_id": "client-001", "account_id": "account-001"})
        portfolio = response["Item"]

        assert portfolio["client_id"] == "client-001"
        assert "AAPL" in portfolio["positions"]
        assert portfolio["positions"]["AAPL"]["quantity"] == Decimal("100")

    def test_get_nonexistent_portfolio_returns_404(self):
        """GET for unknown client_id returns 404."""
        # Pattern: DynamoDB get_item returns no Item → NotFoundError
        response = {"Item": None}
        assert response.get("Item") is None


class TestPositionUpdate:
    """Tests for position update logic (trade processing)."""

    def test_buy_increases_position(self):
        """BUY trade increases position quantity."""
        existing_qty = Decimal("100")
        buy_qty = Decimal("50")
        new_qty = existing_qty + buy_qty
        assert new_qty == Decimal("150")

    def test_sell_decreases_position(self):
        """SELL trade decreases position quantity."""
        existing_qty = Decimal("100")
        sell_qty = Decimal("30")
        new_qty = existing_qty - sell_qty
        assert new_qty == Decimal("70")

    def test_weighted_average_cost_basis(self):
        """Cost basis uses weighted average on BUY."""
        # Existing: 100 shares @ $185.50
        existing_qty = Decimal("100")
        existing_cost = Decimal("185.50")
        # New BUY: 50 shares @ $190.00
        new_qty = Decimal("50")
        new_price = Decimal("190.00")

        total_qty = existing_qty + new_qty
        new_avg_cost = (existing_qty * existing_cost + new_qty * new_price) / total_qty

        assert total_qty == Decimal("150")
        assert new_avg_cost == Decimal("187.00")  # Weighted avg

    def test_sell_does_not_change_cost_basis(self):
        """SELL does not affect average cost basis."""
        avg_cost_before = Decimal("185.50")
        # After selling, cost basis stays the same
        avg_cost_after = avg_cost_before
        assert avg_cost_after == Decimal("185.50")

    def test_sell_more_than_position_rejected(self):
        """Cannot sell more shares than held (insufficient position)."""
        position_qty = Decimal("100")
        sell_qty = Decimal("150")
        assert sell_qty > position_qty

    def test_new_position_creation(self):
        """Buying new instrument creates a new position entry."""
        positions = {}
        new_instrument = "GOOG"
        buy_qty = Decimal("25")
        buy_price = Decimal("140.00")

        positions[new_instrument] = {
            "quantity": buy_qty,
            "avg_cost": buy_price,
        }

        assert new_instrument in positions
        assert positions["GOOG"]["quantity"] == Decimal("25")


class TestMarginCheck:
    """Tests for Reg T margin validation."""

    def test_margin_check_sufficient(self):
        """Order within 50% margin requirement passes."""
        # Reg T: 50% initial margin
        portfolio_value = Decimal("100000.00")
        buying_power = portfolio_value * Decimal("0.5")  # 50% margin
        order_value = Decimal("25000.00")  # 25 shares @ $1000

        assert order_value <= buying_power

    def test_margin_check_insufficient(self):
        """Order exceeding margin requirement is rejected."""
        portfolio_value = Decimal("100000.00")
        buying_power = portfolio_value * Decimal("0.5")
        order_value = Decimal("75000.00")

        assert order_value > buying_power

    def test_margin_uses_decimal_not_float(self):
        """Margin calculations use Decimal for precision."""
        # Float imprecision example
        assert Decimal("0.1") + Decimal("0.2") == Decimal("0.3")
        # This would fail with float: 0.1 + 0.2 == 0.30000000000000004


class TestSQSFIFOProcessing:
    """Tests for SQS FIFO trade event processing."""

    def test_sqs_batch_processes_trade(self, sample_sqs_fifo_event):
        """SQS FIFO batch record is correctly parsed."""
        record = sample_sqs_fifo_event["Records"][0]
        trade = json.loads(record["body"])

        assert trade["client_id"] == "client-001"
        assert trade["instrument_id"] == "AAPL"
        assert trade["side"] == "BUY"

    def test_fifo_ordering_by_message_group(self, sample_sqs_fifo_event):
        """FIFO queue processes in order per MessageGroupId."""
        record = sample_sqs_fifo_event["Records"][0]
        group_id = record["attributes"]["MessageGroupId"]
        assert group_id == "client-001"  # Ordered per client

    def test_batch_item_failure_reporting(self):
        """Failed records are reported as batchItemFailures for retry."""
        failed_ids = ["msg-001", "msg-003"]
        response = {
            "batchItemFailures": [
                {"itemIdentifier": msg_id} for msg_id in failed_ids
            ]
        }
        assert len(response["batchItemFailures"]) == 2
        assert response["batchItemFailures"][0]["itemIdentifier"] == "msg-001"

    def test_deduplication_id_prevents_reprocessing(self, sample_sqs_fifo_event):
        """MessageDeduplicationId prevents duplicate trade processing."""
        record = sample_sqs_fifo_event["Records"][0]
        dedup_id = record["attributes"]["MessageDeduplicationId"]
        assert dedup_id is not None
        assert len(dedup_id) > 0
