"""Wallet Service Data Models.

Defines data classes for portfolio management, position tracking, margin
validation, and trade event processing. All financial calculations use
Decimal to prevent floating-point precision errors per financial standards.

Requirements: 7.1, 7.2
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from decimal import Decimal
from enum import Enum
from typing import Optional


class TradeSide(str, Enum):
    """Trade direction."""

    BUY = "BUY"
    SELL = "SELL"


class OrderType(str, Enum):
    """Order execution type."""

    MARKET = "MARKET"
    LIMIT = "LIMIT"
    STOP = "STOP"
    STOP_LIMIT = "STOP_LIMIT"


class MarginStatus(str, Enum):
    """Margin check result status."""

    APPROVED = "APPROVED"
    REJECTED = "REJECTED"
    PENDING_REVIEW = "PENDING_REVIEW"


@dataclass
class Position:
    """A single instrument position within a portfolio.

    Attributes:
        instrument_id: ISIN/CUSIP identifier for the instrument.
        quantity: Number of shares/units held (can be negative for short).
        avg_cost_basis: Weighted average cost per unit (Decimal precision).
        current_price: Latest market price per unit.
        unrealized_pnl: Unrealized profit/loss based on current price.
        market_value: Total market value (quantity * current_price).
    """

    instrument_id: str
    quantity: Decimal
    avg_cost_basis: Decimal
    current_price: Decimal = Decimal("0")
    unrealized_pnl: Decimal = Decimal("0")
    market_value: Decimal = Decimal("0")

    def calculate_market_value(self) -> Decimal:
        """Calculate market value from quantity and current price."""
        self.market_value = self.quantity * self.current_price
        return self.market_value

    def calculate_unrealized_pnl(self) -> Decimal:
        """Calculate unrealized P&L: (current_price - avg_cost_basis) * quantity."""
        self.unrealized_pnl = (self.current_price - self.avg_cost_basis) * self.quantity
        return self.unrealized_pnl

    def to_dict(self) -> dict:
        """Serialize position to dictionary."""
        return {
            "instrument_id": self.instrument_id,
            "quantity": str(self.quantity),
            "avg_cost_basis": str(self.avg_cost_basis),
            "current_price": str(self.current_price),
            "unrealized_pnl": str(self.unrealized_pnl),
            "market_value": str(self.market_value),
        }

    @classmethod
    def from_dict(cls, data: dict) -> Position:
        """Deserialize position from dictionary."""
        return cls(
            instrument_id=data["instrument_id"],
            quantity=Decimal(str(data["quantity"])),
            avg_cost_basis=Decimal(str(data["avg_cost_basis"])),
            current_price=Decimal(str(data.get("current_price", "0"))),
            unrealized_pnl=Decimal(str(data.get("unrealized_pnl", "0"))),
            market_value=Decimal(str(data.get("market_value", "0"))),
        )


@dataclass
class Portfolio:
    """Complete portfolio state for a client account.

    Attributes:
        client_id: Unique client identifier.
        account_id: Account identifier within the client.
        cash_balance: Available cash balance (Decimal).
        positions: List of open positions.
        margin_available: Available margin for new orders.
        total_value: Total portfolio value (cash + positions market value).
        last_updated: Timestamp of last portfolio update (UTC).
    """

    client_id: str
    account_id: str
    cash_balance: Decimal = Decimal("0")
    positions: list[Position] = field(default_factory=list)
    margin_available: Decimal = Decimal("0")
    total_value: Decimal = Decimal("0")
    last_updated: datetime = field(default_factory=lambda: datetime.now(timezone.utc))

    def calculate_total_value(self) -> Decimal:
        """Calculate total portfolio value: cash + sum of position market values."""
        positions_value = sum(p.market_value for p in self.positions)
        self.total_value = self.cash_balance + positions_value
        return self.total_value

    def calculate_margin_available(self, margin_ratio: Decimal = Decimal("0.5")) -> Decimal:
        """Calculate available margin based on portfolio value and margin ratio.

        Available margin = (total_value * margin_ratio) - sum of position costs.
        Standard margin ratio is 50% (Regulation T initial margin requirement).

        Args:
            margin_ratio: Fraction of portfolio value available as margin.

        Returns:
            Available margin amount.
        """
        total_position_cost = sum(
            p.quantity * p.avg_cost_basis for p in self.positions if p.quantity > 0
        )
        self.margin_available = (self.total_value * margin_ratio) - total_position_cost
        # Margin cannot exceed cash balance
        if self.margin_available > self.cash_balance:
            self.margin_available = self.cash_balance
        return self.margin_available

    def to_dict(self) -> dict:
        """Serialize portfolio to dictionary for API response."""
        return {
            "client_id": self.client_id,
            "account_id": self.account_id,
            "cash_balance": str(self.cash_balance),
            "positions": [p.to_dict() for p in self.positions],
            "margin_available": str(self.margin_available),
            "total_value": str(self.total_value),
            "last_updated": self.last_updated.isoformat(),
        }

    @classmethod
    def from_dynamodb_item(cls, item: dict) -> Portfolio:
        """Deserialize portfolio from DynamoDB item."""
        positions = [
            Position.from_dict(p) for p in item.get("positions", [])
        ]
        return cls(
            client_id=item["client_id"],
            account_id=item["account_id"],
            cash_balance=Decimal(str(item.get("cash_balance", "0"))),
            positions=positions,
            margin_available=Decimal(str(item.get("margin_available", "0"))),
            total_value=Decimal(str(item.get("total_value", "0"))),
            last_updated=datetime.fromisoformat(
                item.get("last_updated", datetime.now(timezone.utc).isoformat())
            ),
        )


@dataclass
class TradeEvent:
    """Represents a trade.executed event from SQS FIFO queue.

    Triggered by the Order Manager when a trade is successfully executed.
    Used by the Wallet Service to update positions and cash balance.

    Attributes:
        order_id: Platform-generated order UUID.
        client_id: Client who placed the order.
        account_id: Account used for the trade.
        instrument_id: ISIN/CUSIP of traded instrument.
        side: BUY or SELL.
        quantity: Number of units traded.
        executed_price: Price at which the trade was executed.
        execution_timestamp: Time of execution (UTC).
        venue: Execution venue identifier.
    """

    order_id: str
    client_id: str
    account_id: str
    instrument_id: str
    side: TradeSide
    quantity: Decimal
    executed_price: Decimal
    execution_timestamp: datetime
    venue: str

    @property
    def trade_value(self) -> Decimal:
        """Total value of the trade (quantity * executed_price)."""
        return self.quantity * self.executed_price

    @classmethod
    def from_sqs_message(cls, message_body: dict) -> TradeEvent:
        """Parse a trade event from SQS FIFO message body.

        Expected format matches the EventBridge trade.executed schema:
        {
            "detail": {
                "order_id": "uuid",
                "client_id": "string",
                "account_id": "string",
                "instrument_id": "string",
                "side": "BUY|SELL",
                "quantity": "number",
                "executed_price": "number",
                "execution_timestamp": "ISO-8601",
                "venue": "string"
            }
        }
        """
        detail = message_body.get("detail", message_body)
        return cls(
            order_id=detail["order_id"],
            client_id=detail["client_id"],
            account_id=detail.get("account_id", "default"),
            instrument_id=detail["instrument_id"],
            side=TradeSide(detail["side"]),
            quantity=Decimal(str(detail["quantity"])),
            executed_price=Decimal(str(detail["executed_price"])),
            execution_timestamp=datetime.fromisoformat(
                detail["execution_timestamp"].replace("Z", "+00:00")
            ),
            venue=detail.get("venue", "unknown"),
        )


@dataclass
class OrderRequest:
    """Order request for margin validation.

    Attributes:
        client_id: Client placing the order.
        account_id: Account to use for the order.
        instrument_id: ISIN/CUSIP of instrument to trade.
        order_type: Type of order (MARKET, LIMIT, STOP, STOP_LIMIT).
        side: BUY or SELL direction.
        quantity: Number of units to trade.
        limit_price: Maximum price for LIMIT orders.
        estimated_price: Estimated execution price for margin calculation.
    """

    client_id: str
    account_id: str
    instrument_id: str
    order_type: OrderType
    side: TradeSide
    quantity: Decimal
    limit_price: Optional[Decimal] = None
    estimated_price: Optional[Decimal] = None

    @property
    def effective_price(self) -> Decimal:
        """Price to use for margin calculation (limit_price or estimated_price)."""
        if self.limit_price is not None:
            return self.limit_price
        if self.estimated_price is not None:
            return self.estimated_price
        return Decimal("0")

    @property
    def order_value(self) -> Decimal:
        """Estimated total value of the order."""
        return self.quantity * self.effective_price

    @classmethod
    def from_dict(cls, data: dict) -> OrderRequest:
        """Parse order request from API request body."""
        return cls(
            client_id=data["client_id"],
            account_id=data.get("account_id", "default"),
            instrument_id=data["instrument_id"],
            order_type=OrderType(data["order_type"]),
            side=TradeSide(data["side"]),
            quantity=Decimal(str(data["quantity"])),
            limit_price=Decimal(str(data["limit_price"])) if data.get("limit_price") else None,
            estimated_price=(
                Decimal(str(data["estimated_price"])) if data.get("estimated_price") else None
            ),
        )


@dataclass
class PositionUpdate:
    """Result of processing a trade event on a position.

    Attributes:
        instrument_id: Instrument that was updated.
        previous_quantity: Quantity before the trade.
        new_quantity: Quantity after the trade.
        previous_avg_cost: Average cost basis before the trade.
        new_avg_cost: Average cost basis after the trade.
        cash_delta: Change in cash balance (negative for BUY, positive for SELL).
        trade_value: Total value of the executed trade.
        timestamp: Time the update was applied.
    """

    instrument_id: str
    previous_quantity: Decimal
    new_quantity: Decimal
    previous_avg_cost: Decimal
    new_avg_cost: Decimal
    cash_delta: Decimal
    trade_value: Decimal
    timestamp: datetime = field(default_factory=lambda: datetime.now(timezone.utc))

    def to_dict(self) -> dict:
        """Serialize position update to dictionary."""
        return {
            "instrument_id": self.instrument_id,
            "previous_quantity": str(self.previous_quantity),
            "new_quantity": str(self.new_quantity),
            "previous_avg_cost": str(self.previous_avg_cost),
            "new_avg_cost": str(self.new_avg_cost),
            "cash_delta": str(self.cash_delta),
            "trade_value": str(self.trade_value),
            "timestamp": self.timestamp.isoformat(),
        }


@dataclass
class MarginResult:
    """Result of a margin validation check.

    Attributes:
        status: APPROVED, REJECTED, or PENDING_REVIEW.
        available_margin: Current available margin before this order.
        required_margin: Margin required for the proposed order.
        margin_after_trade: Projected margin if order executes.
        rejection_reason: Reason if status is REJECTED.
        order_value: Total estimated value of the order.
    """

    status: MarginStatus
    available_margin: Decimal
    required_margin: Decimal
    margin_after_trade: Decimal
    rejection_reason: Optional[str] = None
    order_value: Decimal = Decimal("0")

    def to_dict(self) -> dict:
        """Serialize margin result to dictionary for API response."""
        result = {
            "status": self.status.value,
            "available_margin": str(self.available_margin),
            "required_margin": str(self.required_margin),
            "margin_after_trade": str(self.margin_after_trade),
            "order_value": str(self.order_value),
        }
        if self.rejection_reason:
            result["rejection_reason"] = self.rejection_reason
        return result
