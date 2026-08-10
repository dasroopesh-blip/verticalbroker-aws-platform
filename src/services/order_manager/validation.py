"""Pre-trade validation for Order Manager.

Implements validation checks required before order acceptance:
- Margin sufficiency check via WalletService
- Position limit validation
- Market hours validation
- Instrument existence verification
- Order field validation (types, ranges, required fields)

Requirements: 7.1, 7.2, 8.4
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from datetime import datetime, time, timezone
from decimal import Decimal
from enum import Enum
from typing import Optional

import boto3
from aws_lambda_powertools import Logger, Tracer

logger = Logger(child=True)
tracer = Tracer()


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

VALID_ORDER_TYPES = {"MARKET", "LIMIT", "STOP", "STOP_LIMIT"}
VALID_SIDES = {"BUY", "SELL"}
VALID_TIME_IN_FORCE = {"DAY", "GTC", "IOC", "FOK"}

# US market hours (Eastern Time) - pre-market 4:00 AM, post-market 8:00 PM
MARKET_OPEN = time(4, 0)  # Pre-market open
MARKET_CLOSE = time(20, 0)  # Post-market close
REGULAR_OPEN = time(9, 30)
REGULAR_CLOSE = time(16, 0)

# Position limits
DEFAULT_MAX_POSITION_VALUE = Decimal("10000000")  # $10M per instrument
DEFAULT_MAX_ORDER_QUANTITY = Decimal("1000000")  # 1M shares per order


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------


class ValidationError(Exception):
    """Raised when order request fails field-level validation."""

    def __init__(self, message: str, field: Optional[str] = None):
        self.message = message
        self.field = field
        super().__init__(self.message)


class InsufficientMarginError(Exception):
    """Raised when account has insufficient margin for the order."""

    def __init__(
        self,
        required_margin: Decimal,
        available_margin: Decimal,
        account_id: str,
    ):
        self.required_margin = required_margin
        self.available_margin = available_margin
        self.account_id = account_id
        self.message = (
            f"Insufficient margin for account {account_id}: "
            f"required={required_margin}, available={available_margin}"
        )
        super().__init__(self.message)


class InstrumentNotFoundError(Exception):
    """Raised when the specified instrument does not exist."""

    def __init__(self, instrument_id: str):
        self.instrument_id = instrument_id
        self.message = f"Instrument not found: {instrument_id}"
        super().__init__(self.message)


class MarketClosedError(Exception):
    """Raised when order is submitted outside market hours."""

    def __init__(self, current_time: time, message: Optional[str] = None):
        self.current_time = current_time
        self.message = message or (
            f"Market is closed. Current time: {current_time}. "
            f"Trading hours: {MARKET_OPEN} - {MARKET_CLOSE} ET"
        )
        super().__init__(self.message)


class PositionLimitExceededError(Exception):
    """Raised when order would exceed position limits."""

    def __init__(
        self,
        instrument_id: str,
        current_position: Decimal,
        order_quantity: Decimal,
        limit: Decimal,
    ):
        self.instrument_id = instrument_id
        self.current_position = current_position
        self.order_quantity = order_quantity
        self.limit = limit
        self.message = (
            f"Position limit exceeded for {instrument_id}: "
            f"current={current_position}, order={order_quantity}, limit={limit}"
        )
        super().__init__(self.message)


# ---------------------------------------------------------------------------
# Data Classes
# ---------------------------------------------------------------------------


class ValidationSeverity(str, Enum):
    """Severity level of a validation issue."""

    ERROR = "ERROR"
    WARNING = "WARNING"


@dataclass
class ValidationIssue:
    """A single validation issue found during pre-trade checks."""

    field: str
    message: str
    severity: ValidationSeverity = ValidationSeverity.ERROR


@dataclass
class ValidationResult:
    """Result of pre-trade validation."""

    is_valid: bool
    issues: list[ValidationIssue] = field(default_factory=list)
    margin_available: Optional[Decimal] = None
    margin_required: Optional[Decimal] = None

    def add_error(self, field: str, message: str) -> None:
        """Add an error-level validation issue."""
        self.issues.append(
            ValidationIssue(
                field=field,
                message=message,
                severity=ValidationSeverity.ERROR,
            )
        )
        self.is_valid = False

    def add_warning(self, field: str, message: str) -> None:
        """Add a warning-level validation issue."""
        self.issues.append(
            ValidationIssue(
                field=field,
                message=message,
                severity=ValidationSeverity.WARNING,
            )
        )


@dataclass
class MarginCheckResult:
    """Result from WalletService margin check."""

    is_sufficient: bool
    available_margin: Decimal
    required_margin: Decimal
    account_id: str


# ---------------------------------------------------------------------------
# Validation Functions
# ---------------------------------------------------------------------------


@tracer.capture_method
def validate_order_fields(order_data: dict) -> ValidationResult:
    """Validate order request fields for correctness and completeness.

    Checks:
        - Required fields are present and non-empty
        - order_type is one of MARKET, LIMIT, STOP, STOP_LIMIT
        - side is BUY or SELL
        - time_in_force is DAY, GTC, IOC, or FOK
        - quantity is positive
        - limit_price is provided for LIMIT and STOP_LIMIT orders
        - stop_price is provided for STOP and STOP_LIMIT orders
        - idempotency_key is present

    Args:
        order_data: Raw order request dictionary from API.

    Returns:
        ValidationResult with any field-level issues.
    """
    result = ValidationResult(is_valid=True)

    # Required fields
    required_fields = [
        "client_id",
        "account_id",
        "instrument_id",
        "order_type",
        "side",
        "quantity",
        "time_in_force",
        "idempotency_key",
    ]

    for field_name in required_fields:
        if not order_data.get(field_name):
            result.add_error(field_name, f"{field_name} is required")

    # Early return if missing required fields
    if not result.is_valid:
        return result

    # Order type validation
    order_type = order_data.get("order_type", "").upper()
    if order_type not in VALID_ORDER_TYPES:
        result.add_error(
            "order_type",
            f"Invalid order_type: {order_type}. Must be one of: {', '.join(sorted(VALID_ORDER_TYPES))}",
        )

    # Side validation
    side = order_data.get("side", "").upper()
    if side not in VALID_SIDES:
        result.add_error(
            "side",
            f"Invalid side: {side}. Must be BUY or SELL",
        )

    # Time in force validation
    tif = order_data.get("time_in_force", "").upper()
    if tif not in VALID_TIME_IN_FORCE:
        result.add_error(
            "time_in_force",
            f"Invalid time_in_force: {tif}. Must be one of: {', '.join(sorted(VALID_TIME_IN_FORCE))}",
        )

    # Quantity validation
    try:
        quantity = Decimal(str(order_data.get("quantity", 0)))
        if quantity <= 0:
            result.add_error("quantity", "Quantity must be positive")
        if quantity > DEFAULT_MAX_ORDER_QUANTITY:
            result.add_error(
                "quantity",
                f"Quantity exceeds maximum allowed: {DEFAULT_MAX_ORDER_QUANTITY}",
            )
    except Exception:
        result.add_error("quantity", "Quantity must be a valid number")

    # Price validation based on order type
    if order_type in ("LIMIT", "STOP_LIMIT"):
        limit_price = order_data.get("limit_price")
        if limit_price is None:
            result.add_error(
                "limit_price",
                f"limit_price is required for {order_type} orders",
            )
        else:
            try:
                lp = Decimal(str(limit_price))
                if lp <= 0:
                    result.add_error("limit_price", "limit_price must be positive")
            except Exception:
                result.add_error("limit_price", "limit_price must be a valid number")

    if order_type in ("STOP", "STOP_LIMIT"):
        stop_price = order_data.get("stop_price")
        if stop_price is None:
            result.add_error(
                "stop_price",
                f"stop_price is required for {order_type} orders",
            )
        else:
            try:
                sp = Decimal(str(stop_price))
                if sp <= 0:
                    result.add_error("stop_price", "stop_price must be positive")
            except Exception:
                result.add_error("stop_price", "stop_price must be a valid number")

    return result


@tracer.capture_method
def validate_market_hours(
    current_time: Optional[datetime] = None,
    allow_extended_hours: bool = True,
) -> ValidationResult:
    """Validate that the order is being submitted during market hours.

    US Equity market hours (Eastern Time):
        - Pre-market: 4:00 AM - 9:30 AM
        - Regular: 9:30 AM - 4:00 PM
        - After-hours: 4:00 PM - 8:00 PM

    Args:
        current_time: Override for testing; defaults to UTC now.
        allow_extended_hours: Whether to allow pre/post market orders.

    Returns:
        ValidationResult indicating whether market is open.
    """
    result = ValidationResult(is_valid=True)

    if current_time is None:
        current_time = datetime.now(timezone.utc)

    # Convert to Eastern Time (simplified; production would use pytz/zoneinfo)
    # UTC-5 (EST) or UTC-4 (EDT) - using UTC-4 as conservative estimate
    eastern_offset = -4
    eastern_hour = (current_time.hour + eastern_offset) % 24
    eastern_minute = current_time.minute
    current_et = time(eastern_hour, eastern_minute)

    # Check if weekend (Saturday=5, Sunday=6)
    if current_time.weekday() >= 5:
        result.add_error(
            "market_hours",
            "Market is closed on weekends",
        )
        return result

    # Check trading hours
    if allow_extended_hours:
        if current_et < MARKET_OPEN or current_et >= MARKET_CLOSE:
            result.add_error(
                "market_hours",
                f"Market is closed. Extended hours: {MARKET_OPEN}-{MARKET_CLOSE} ET. "
                f"Current time: {current_et} ET",
            )
    else:
        if current_et < REGULAR_OPEN or current_et >= REGULAR_CLOSE:
            result.add_error(
                "market_hours",
                f"Market is closed. Regular hours: {REGULAR_OPEN}-{REGULAR_CLOSE} ET. "
                f"Current time: {current_et} ET",
            )

    return result


@tracer.capture_method
def validate_instrument(instrument_id: str) -> ValidationResult:
    """Validate that the instrument exists in the platform's instrument registry.

    Checks DynamoDB InstrumentRegistry table for the given ISIN/CUSIP.

    Args:
        instrument_id: ISIN or CUSIP identifier.

    Returns:
        ValidationResult; invalid if instrument not found.

    Raises:
        InstrumentNotFoundError: If instrument does not exist.
    """
    result = ValidationResult(is_valid=True)

    if not instrument_id or len(instrument_id) < 6:
        result.add_error(
            "instrument_id",
            "Invalid instrument_id format. Must be a valid ISIN or CUSIP.",
        )
        return result

    table_name = os.environ.get("INSTRUMENT_TABLE", "InstrumentRegistry")
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(table_name)

    try:
        response = table.get_item(
            Key={"instrument_id": instrument_id},
            ProjectionExpression="instrument_id, #s, instrument_type",
            ExpressionAttributeNames={"#s": "status"},
        )
        item = response.get("Item")

        if not item:
            raise InstrumentNotFoundError(instrument_id)

        # Check if instrument is active/tradeable
        status = item.get("status", "INACTIVE")
        if status != "ACTIVE":
            result.add_error(
                "instrument_id",
                f"Instrument {instrument_id} is not tradeable (status: {status})",
            )

    except InstrumentNotFoundError:
        raise
    except Exception as e:
        logger.error(f"Error validating instrument: {e}")
        result.add_error(
            "instrument_id",
            f"Unable to validate instrument: {instrument_id}",
        )

    return result


@tracer.capture_method
def check_margin(
    client_id: str,
    account_id: str,
    instrument_id: str,
    side: str,
    quantity: Decimal,
    limit_price: Optional[Decimal] = None,
) -> MarginCheckResult:
    """Check margin sufficiency via WalletService.

    Calculates required margin for the order and verifies availability
    against the client's account via DynamoDB Accounts table.

    Args:
        client_id: Client identifier.
        account_id: Trading account identifier.
        instrument_id: ISIN/CUSIP of the instrument.
        side: BUY or SELL.
        quantity: Order quantity.
        limit_price: Limit price for limit orders; used as order value estimate.

    Returns:
        MarginCheckResult with sufficiency determination.

    Raises:
        InsufficientMarginError: If margin is insufficient for the order.
    """
    table_name = os.environ.get("ACCOUNTS_TABLE", "Accounts")
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(table_name)

    # Retrieve account margin information
    try:
        response = table.get_item(
            Key={"account_id": account_id, "client_id": client_id},
            ProjectionExpression="margin_available, cash_balance, buying_power",
        )
        item = response.get("Item")

        if not item:
            raise InsufficientMarginError(
                required_margin=Decimal("0"),
                available_margin=Decimal("0"),
                account_id=account_id,
            )

        available_margin = Decimal(str(item.get("margin_available", "0")))

    except InsufficientMarginError:
        raise
    except Exception as e:
        logger.error(f"Error checking margin: {e}")
        # Fail closed: reject if unable to verify margin
        raise InsufficientMarginError(
            required_margin=Decimal("0"),
            available_margin=Decimal("0"),
            account_id=account_id,
        )

    # Calculate required margin for the order
    # Use limit_price if available, otherwise estimate with a reference price
    estimated_price = limit_price if limit_price else _get_reference_price(instrument_id)
    required_margin = _calculate_required_margin(
        side=side,
        quantity=quantity,
        price=estimated_price,
    )

    is_sufficient = available_margin >= required_margin

    if not is_sufficient:
        raise InsufficientMarginError(
            required_margin=required_margin,
            available_margin=available_margin,
            account_id=account_id,
        )

    return MarginCheckResult(
        is_sufficient=True,
        available_margin=available_margin,
        required_margin=required_margin,
        account_id=account_id,
    )


@tracer.capture_method
def check_position_limits(
    client_id: str,
    account_id: str,
    instrument_id: str,
    side: str,
    quantity: Decimal,
) -> ValidationResult:
    """Validate that the order does not exceed position limits.

    Args:
        client_id: Client identifier.
        account_id: Trading account identifier.
        instrument_id: ISIN/CUSIP identifier.
        side: BUY or SELL.
        quantity: Order quantity.

    Returns:
        ValidationResult indicating whether position limits are satisfied.
    """
    result = ValidationResult(is_valid=True)

    table_name = os.environ.get("POSITIONS_TABLE", "Positions")
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(table_name)

    try:
        response = table.get_item(
            Key={
                "account_id": account_id,
                "instrument_id": instrument_id,
            },
            ProjectionExpression="quantity, market_value",
        )
        item = response.get("Item")

        current_quantity = Decimal(str(item.get("quantity", "0"))) if item else Decimal("0")

        # For BUY orders, add to position; for SELL, ensure we have enough to sell
        if side == "BUY":
            new_quantity = current_quantity + quantity
            if new_quantity > DEFAULT_MAX_ORDER_QUANTITY:
                raise PositionLimitExceededError(
                    instrument_id=instrument_id,
                    current_position=current_quantity,
                    order_quantity=quantity,
                    limit=DEFAULT_MAX_ORDER_QUANTITY,
                )
        elif side == "SELL":
            # For short selling or selling more than held
            if quantity > current_quantity:
                result.add_warning(
                    "quantity",
                    f"Sell quantity ({quantity}) exceeds current position ({current_quantity}). "
                    f"This will create a short position.",
                )

    except PositionLimitExceededError:
        raise
    except Exception as e:
        logger.warning(f"Error checking position limits: {e}")
        # Non-blocking warning; don't fail the order
        result.add_warning(
            "position_limits",
            "Unable to verify position limits. Order will proceed with caution.",
        )

    return result


# ---------------------------------------------------------------------------
# Private Helpers
# ---------------------------------------------------------------------------


def _get_reference_price(instrument_id: str) -> Decimal:
    """Get last known price for margin calculation.

    Falls back to a conservative estimate if price is unavailable.

    Args:
        instrument_id: ISIN/CUSIP identifier.

    Returns:
        Reference price as Decimal.
    """
    table_name = os.environ.get("MARKET_DATA_TABLE", "MarketDataLatest")
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(table_name)

    try:
        response = table.get_item(
            Key={"instrument_id": instrument_id},
            ProjectionExpression="last_price",
        )
        item = response.get("Item")
        if item and item.get("last_price"):
            return Decimal(str(item["last_price"]))
    except Exception as e:
        logger.warning(f"Unable to get reference price for {instrument_id}: {e}")

    # Conservative fallback: use a high estimate to avoid under-margining
    return Decimal("1000.00")


def _calculate_required_margin(
    side: str,
    quantity: Decimal,
    price: Decimal,
    margin_requirement: Decimal = Decimal("0.50"),
) -> Decimal:
    """Calculate margin required for an order.

    Uses Regulation T initial margin requirement (50% for equities).

    Args:
        side: BUY or SELL.
        quantity: Number of shares/units.
        price: Estimated execution price.
        margin_requirement: Fraction of notional required (default 50%).

    Returns:
        Required margin as Decimal.
    """
    notional_value = quantity * price

    if side == "BUY":
        # Long position: Reg T 50% initial margin
        return notional_value * margin_requirement
    else:
        # Short position: 150% of notional (100% proceeds + 50% margin)
        return notional_value * (Decimal("1") + margin_requirement)
