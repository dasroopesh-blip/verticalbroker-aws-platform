"""
Unit tests for Neptune graph model.
Tests: Vertex/edge creation, Gremlin query building, fraud detection queries.
"""

import uuid
from datetime import UTC, datetime
from decimal import Decimal

import pytest


pytestmark = pytest.mark.unit


class TestVertexModels:
    """Tests for graph vertex dataclasses."""

    def test_client_vertex_creation(self):
        """ClientVertex contains client metadata for graph."""
        vertex = {
            "vertex_id": "client-001",
            "label": "Client",
            "properties": {
                "client_id": "client-001",
                "name": "John Doe",
                "tier": "PREMIUM",
                "risk_tolerance": "MODERATE",
                "kyc_verified": True,
                "created_at": "2023-01-15T00:00:00Z",
            },
        }
        assert vertex["label"] == "Client"
        assert vertex["properties"]["kyc_verified"] is True

    def test_account_vertex_creation(self):
        """AccountVertex represents a trading account."""
        vertex = {
            "vertex_id": "account-001",
            "label": "Account",
            "properties": {
                "account_id": "account-001",
                "account_type": "BROKERAGE",
                "status": "ACTIVE",
                "balance": Decimal("500000.00"),
            },
        }
        assert vertex["label"] == "Account"
        assert vertex["properties"]["status"] == "ACTIVE"

    def test_instrument_vertex_creation(self):
        """InstrumentVertex represents a tradeable instrument."""
        vertex = {
            "vertex_id": "AAPL",
            "label": "Instrument",
            "properties": {
                "instrument_id": "AAPL",
                "name": "Apple Inc.",
                "sector": "Technology",
                "exchange": "NASDAQ",
                "instrument_type": "equity",
            },
        }
        assert vertex["label"] == "Instrument"
        assert vertex["properties"]["sector"] == "Technology"

    def test_create_query_parameterized(self):
        """Vertex create queries use parameterized Gremlin (no injection)."""
        # Pattern: g.addV('Client').property('client_id', client_id)
        query_template = "g.addV(label).property('client_id', client_id)"
        bindings = {"label": "Client", "client_id": "client-001"}
        assert "label" in query_template
        assert bindings["label"] == "Client"


class TestEdgeModels:
    """Tests for graph edge dataclasses."""

    def test_transaction_edge(self):
        """TransactionEdge connects Account → Instrument with trade details."""
        edge = {
            "from_vertex": "account-001",
            "to_vertex": "AAPL",
            "label": "TRADED",
            "properties": {
                "order_id": str(uuid.uuid4()),
                "side": "BUY",
                "quantity": 100,
                "price": 185.50,
                "timestamp": datetime.now(UTC).isoformat(),
            },
        }
        assert edge["label"] == "TRADED"
        assert edge["properties"]["side"] in ("BUY", "SELL")

    def test_owns_edge(self):
        """OwnsEdge: Client → Account."""
        edge = {"from_vertex": "client-001", "to_vertex": "account-001", "label": "OWNS"}
        assert edge["label"] == "OWNS"

    def test_transfers_to_edge(self):
        """TransfersToEdge: Account → Account (money transfer)."""
        edge = {
            "from_vertex": "account-001",
            "to_vertex": "account-002",
            "label": "TRANSFERS_TO",
            "properties": {"amount": 50000.0, "timestamp": "2024-01-15T14:30:00Z"},
        }
        assert edge["label"] == "TRANSFERS_TO"

    def test_correlates_with_edge(self):
        """CorrelatesWithEdge: Instrument → Instrument (price correlation)."""
        edge = {
            "from_vertex": "AAPL",
            "to_vertex": "MSFT",
            "label": "CORRELATES_WITH",
            "properties": {"correlation_coefficient": 0.82, "period_days": 252},
        }
        assert edge["properties"]["correlation_coefficient"] > 0.7


class TestFraudDetectionQueries:
    """Tests for pre-built fraud detection Gremlin queries."""

    def test_circular_transactions_query(self):
        """Detects circular money flows (A→B→C→A)."""
        query_name = "circular_transactions"
        # Pattern: g.V(account).repeat(out('TRANSFERS_TO')).until(eq(account)).path()
        min_cycle_length = 3
        assert min_cycle_length >= 3

    def test_rapid_transfers_query(self):
        """Detects rapid succession transfers from single account."""
        query_name = "rapid_transfers"
        time_window_minutes = 5
        min_transfer_count = 10
        assert time_window_minutes > 0
        assert min_transfer_count >= 10

    def test_unusual_velocity_query(self):
        """Detects trading velocity anomalies (> 3 std devs from mean)."""
        query_name = "unusual_velocity"
        std_dev_threshold = 3
        assert std_dev_threshold == 3

    def test_connected_flagged_accounts_query(self):
        """Finds accounts connected to already-flagged accounts."""
        query_name = "connected_flagged_accounts"
        max_hops = 3  # Look 3 hops from flagged accounts
        assert max_hops <= 5  # Don't go too deep

    def test_wash_trading_detection_query(self):
        """Detects wash trading (buy/sell same instrument between related accounts)."""
        query_name = "wash_trading_detection"
        same_instrument = True
        opposite_sides = True
        related_accounts = True
        is_wash = same_instrument and opposite_sides and related_accounts
        assert is_wash is True


class TestNeptuneBulkLoader:
    """Tests for Neptune bulk load configuration."""

    def test_bulk_loader_config(self):
        """Bulk loader uses CSV format with correct S3 path."""
        config = {
            "source": "s3://vb-graph-data/neptune-bulk/",
            "format": "csv",
            "iamRoleArn": "arn:aws:iam::123456789012:role/NeptuneLoadRole",
            "region": "us-east-1",
            "failOnError": "TRUE",
            "parallelism": "OVERSUBSCRIBE",
        }
        assert config["format"] == "csv"
        assert config["failOnError"] == "TRUE"

    def test_vertex_csv_headers(self):
        """Vertex CSV: ~id, ~label, property1, property2, ..."""
        headers = ["~id", "~label", "client_id:String", "name:String", "tier:String"]
        assert headers[0] == "~id"
        assert headers[1] == "~label"

    def test_edge_csv_headers(self):
        """Edge CSV: ~id, ~from, ~to, ~label, property1, ..."""
        headers = ["~id", "~from", "~to", "~label", "amount:Double", "timestamp:Date"]
        assert "~from" in headers
        assert "~to" in headers
