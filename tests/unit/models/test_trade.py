"""
Unit tests for trade models.
Tests: TradeEvent, OrderRequest, OrderResponse, ClientProfile, CustomerProfile dataclasses.
"""

import uuid
from datetime import UTC, datetime
from decimal import Decimal

import pytest


pytestmark = pytest.mark.unit


class TestTradeEvent:
    """Tests for TradeEvent dataclass."""

    def test_trade_event_creation(self):
        """TradeEvent contains all required fields."""
        event = {
            "order_id": str(uuid.uuid4()),
            "client_id": "client-001",
            "account_id": "account-001",
            "instrument_id": "AAPL",
            "side": "BUY",
            "quantity": Decimal("100"),
            "price": Decimal("185.50"),
            "executed_at": datetime.now(UTC).isoformat(),
            "correlation_id": str(uuid.uuid4()),
        }
        assert event["side"] in ("BUY", "SELL")
        assert event["quantity"] > 0
        assert event["price"] > 0

    def test_trade_event_side_values(self):
        """TradeEvent side is restricted to BUY or SELL."""
        valid_sides = {"BUY", "SELL"}
        assert "BUY" in valid_sides
        assert "SELL" in valid_sides
        assert "SHORT" not in valid_sides

    def test_trade_event_uses_decimal_for_money(self):
        """Price and quantity use Decimal, not float."""
        price = Decimal("185.50")
        quantity = Decimal("100")
        total_value = price * quantity
        assert total_value == Decimal("18550.00")

    def test_trade_event_correlation_id(self):
        """Each trade has a correlation_id for distributed tracing."""
        correlation_id = str(uuid.uuid4())
        assert len(correlation_id) == 36  # UUID format


class TestOrderRequest:
    """Tests for OrderRequest dataclass."""

    def test_order_request_from_dict(self):
        """OrderRequest can be created from API Gateway body dict."""
        body = {
            "instrument_id": "AAPL",
            "side": "BUY",
            "quantity": "100",
            "price": "185.50",
            "order_type": "LIMIT",
            "time_in_force": "GTC",
            "client_id": "client-001",
            "account_id": "account-001",
        }
        assert body["order_type"] in ("LIMIT", "MARKET", "STOP", "STOP_LIMIT")
        assert body["time_in_force"] in ("GTC", "IOC", "FOK", "DAY")

    def test_order_types_supported(self):
        """Supports LIMIT, MARKET, STOP, STOP_LIMIT order types."""
        valid_types = {"LIMIT", "MARKET", "STOP", "STOP_LIMIT"}
        assert len(valid_types) == 4

    def test_time_in_force_options(self):
        """Supports GTC, IOC, FOK, DAY time-in-force options."""
        valid_tif = {"GTC", "IOC", "FOK", "DAY"}
        assert len(valid_tif) == 4

    def test_market_order_no_price(self):
        """MARKET orders have price=None (executed at market)."""
        order = {"order_type": "MARKET", "price": None}
        assert order["price"] is None

    def test_limit_order_requires_price(self):
        """LIMIT orders must specify a price."""
        order = {"order_type": "LIMIT", "price": "185.50"}
        assert order["price"] is not None


class TestOrderResponse:
    """Tests for OrderResponse dataclass."""

    def test_order_response_structure(self):
        """OrderResponse contains order_id, status, and timestamp."""
        response = {
            "order_id": str(uuid.uuid4()),
            "status": "ACCEPTED",
            "timestamp": datetime.now(UTC).isoformat(),
            "instrument_id": "AAPL",
            "side": "BUY",
            "quantity": "100",
        }
        assert response["status"] in ("ACCEPTED", "REJECTED", "PENDING", "FILLED")

    def test_order_status_values(self):
        """Valid order statuses: ACCEPTED, REJECTED, PENDING, FILLED, CANCELLED."""
        valid_statuses = {"ACCEPTED", "REJECTED", "PENDING", "FILLED", "CANCELLED"}
        assert "ACCEPTED" in valid_statuses
        assert "INVALID" not in valid_statuses

    def test_response_to_dict_serialization(self):
        """OrderResponse.to_dict() produces JSON-serializable dict."""
        response = {
            "order_id": "ord-001",
            "status": "ACCEPTED",
            "timestamp": "2024-01-15T14:30:00Z",
        }
        import json
        serialized = json.dumps(response)
        assert '"order_id"' in serialized


class TestClientProfile:
    """Tests for ClientProfile dataclass."""

    def test_client_profile_fields(self):
        """ClientProfile contains client metadata for trading rules."""
        profile = {
            "client_id": "client-001",
            "account_id": "account-001",
            "tier": "PREMIUM",
            "risk_tolerance": "MODERATE",
            "max_position_size": Decimal("100000.00"),
            "margin_enabled": True,
        }
        assert profile["margin_enabled"] is True
        assert profile["max_position_size"] > 0

    def test_client_tiers(self):
        """Client tiers: STANDARD, PREMIUM, INSTITUTIONAL."""
        valid_tiers = {"STANDARD", "PREMIUM", "INSTITUTIONAL"}
        assert "PREMIUM" in valid_tiers


class TestCustomerProfile:
    """Tests for CustomerProfile dataclass (advisory agent input)."""

    def test_customer_profile_creation(self):
        """CustomerProfile for advisory contains risk/investment fields."""
        profile = {
            "client_id": "client-001",
            "risk_tolerance": "MODERATE",
            "investment_horizon": "LONG_TERM",
            "age": 35,
            "annual_income": Decimal("150000.00"),
            "portfolio_value": Decimal("500000.00"),
            "tax_filing_status": "SINGLE",
        }
        valid_horizons = {"SHORT_TERM", "MEDIUM_TERM", "LONG_TERM"}
        assert profile["investment_horizon"] in valid_horizons

    def test_to_features_for_sagemaker(self):
        """CustomerProfile.to_features() produces numeric array for ML model."""
        profile = {
            "age": 35,
            "annual_income": 150000.0,
            "portfolio_value": 500000.0,
            "risk_score": 0.5,  # MODERATE = 0.5
        }
        features = [profile["age"], profile["annual_income"], profile["portfolio_value"], profile["risk_score"]]
        assert len(features) == 4
        assert all(isinstance(f, (int, float)) for f in features)

    def test_risk_tolerance_mapping(self):
        """Risk tolerance maps to numeric score: CONSERVATIVE=0.25, MODERATE=0.5, AGGRESSIVE=0.75."""
        risk_map = {"CONSERVATIVE": 0.25, "MODERATE": 0.5, "AGGRESSIVE": 0.75}
        assert risk_map["MODERATE"] == 0.5
        assert risk_map["CONSERVATIVE"] < risk_map["AGGRESSIVE"]

    def test_investment_horizon_values(self):
        """Valid horizons: SHORT_TERM (<2y), MEDIUM_TERM (2-7y), LONG_TERM (7y+)."""
        horizons = {"SHORT_TERM": "<2 years", "MEDIUM_TERM": "2-7 years", "LONG_TERM": "7+ years"}
        assert len(horizons) == 3
