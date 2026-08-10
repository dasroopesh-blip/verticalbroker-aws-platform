"""Wallet Service Lambda Handler.

Manages client portfolios, positions, and margin validation for VerticalBroker.
Provides:
- REST API: GET /v1/portfolio/{client_id} for portfolio retrieval
- SQS FIFO event processing: trade.executed events update positions
- Internal margin check: validates order acceptance in real-time

DynamoDB Portfolio Table Schema:
    PK: client_id (string)
    SK: account_id (string)
    Attributes: cash_balance, positions, margin_available, total_value, last_updated

Uses Lambda Powertools for structured logging, X-Ray tracing, and metrics.
All financial calculations use Decimal (no float) for precision.

Requirements: 7.1, 7.2
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from typing import Any

import boto3
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.event_handler import APIGatewayHttpResolver
from aws_lambda_powertools.event_handler.exceptions import NotFoundError
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext
from boto3.dynamodb.conditions import Key

from src.services.wallet.models import (
    MarginResult,
    MarginStatus,
    OrderRequest,
    Portfolio,
    Position,
    PositionUpdate,
    TradeEvent,
    TradeSide,
)

# Lambda Powertools initialization
logger = Logger(service="wallet-service")
tracer = Tracer(service="wallet-service")
metrics = Metrics(namespace="VerticalBroker/Wallet")
app = APIGatewayHttpResolver()

# Environment configuration
PORTFOLIO_TABLE_NAME = os.environ.get("PORTFOLIO_TABLE_NAME", "Portfolio")
MARGIN_RATIO = Decimal(os.environ.get("MARGIN_RATIO", "0.5"))  # Reg T: 50%
MAINTENANCE_MARGIN_RATIO = Decimal(os.environ.get("MAINTENANCE_MARGIN_RATIO", "0.25"))


class WalletService:
    """Manages client account balances and positions.

    Provides portfolio retrieval, event-driven position updates, and
    real-time margin validation using DynamoDB as the state store.
    """

    def __init__(self, table_name: str = PORTFOLIO_TABLE_NAME):
        """Initialize WalletService with DynamoDB table connection.

        Args:
            table_name: Name of the DynamoDB Portfolio table.
        """
        self._dynamodb = boto3.resource("dynamodb")
        self._table = self._dynamodb.Table(table_name)
        self._table_name = table_name

    @tracer.capture_method
    def get_portfolio(self, client_id: str, account_id: str = "default") -> Portfolio:
        """Retrieve current portfolio positions and cash balance from DynamoDB.

        Queries the Portfolio table by client_id and account_id, calculates
        unrealized P&L for all positions, and computes total portfolio value.

        Args:
            client_id: Unique client identifier.
            account_id: Account identifier (defaults to "default").

        Returns:
            Portfolio object with positions, cash balance, and calculated metrics.

        Raises:
            NotFoundError: If no portfolio exists for the given client/account.
        """
        logger.info(
            "Retrieving portfolio",
            extra={"client_id": client_id, "account_id": account_id},
        )

        response = self._table.get_item(
            Key={"client_id": client_id, "account_id": account_id}
        )

        item = response.get("Item")
        if not item:
            logger.warning(
                "Portfolio not found",
                extra={"client_id": client_id, "account_id": account_id},
            )
            raise NotFoundError(
                f"Portfolio not found for client_id={client_id}, account_id={account_id}"
            )

        portfolio = Portfolio.from_dynamodb_item(item)

        # Calculate unrealized P&L for each position
        for position in portfolio.positions:
            position.calculate_market_value()
            position.calculate_unrealized_pnl()

        # Recalculate portfolio totals
        portfolio.calculate_total_value()
        portfolio.calculate_margin_available(MARGIN_RATIO)

        metrics.add_metric(name="PortfolioRetrieved", unit=MetricUnit.Count, value=1)
        logger.info(
            "Portfolio retrieved successfully",
            extra={
                "client_id": client_id,
                "account_id": account_id,
                "total_value": str(portfolio.total_value),
                "position_count": len(portfolio.positions),
            },
        )

        return portfolio

    @tracer.capture_method
    def update_position(self, trade_event: TradeEvent) -> PositionUpdate:
        """Update position based on executed trade event.

        Triggered by trade.executed events from the SQS FIFO queue
        (trade-processing.fifo). Updates:
        - Position quantity (add for BUY, subtract for SELL)
        - Average cost basis (weighted average for BUY)
        - Cash balance (decrease for BUY, increase for SELL)

        Args:
            trade_event: Parsed trade execution event from SQS.

        Returns:
            PositionUpdate with details of the changes made.
        """
        logger.info(
            "Processing trade event for position update",
            extra={
                "order_id": trade_event.order_id,
                "client_id": trade_event.client_id,
                "instrument_id": trade_event.instrument_id,
                "side": trade_event.side.value,
                "quantity": str(trade_event.quantity),
                "executed_price": str(trade_event.executed_price),
            },
        )

        # Retrieve current portfolio state
        try:
            portfolio = self.get_portfolio(trade_event.client_id, trade_event.account_id)
        except NotFoundError:
            # Create new portfolio if none exists
            portfolio = Portfolio(
                client_id=trade_event.client_id,
                account_id=trade_event.account_id,
                cash_balance=Decimal("0"),
                positions=[],
            )

        # Find existing position for the instrument
        existing_position = None
        for pos in portfolio.positions:
            if pos.instrument_id == trade_event.instrument_id:
                existing_position = pos
                break

        # Calculate position update
        previous_quantity = existing_position.quantity if existing_position else Decimal("0")
        previous_avg_cost = (
            existing_position.avg_cost_basis if existing_position else Decimal("0")
        )

        if trade_event.side == TradeSide.BUY:
            new_quantity = previous_quantity + trade_event.quantity
            # Weighted average cost basis for buys
            if new_quantity > 0:
                total_cost = (previous_quantity * previous_avg_cost) + (
                    trade_event.quantity * trade_event.executed_price
                )
                new_avg_cost = total_cost / new_quantity
            else:
                new_avg_cost = trade_event.executed_price
            cash_delta = -(trade_event.trade_value)
        else:
            # SELL
            new_quantity = previous_quantity - trade_event.quantity
            # Average cost basis unchanged on sell
            new_avg_cost = previous_avg_cost
            cash_delta = trade_event.trade_value

        # Update or create position
        if existing_position:
            existing_position.quantity = new_quantity
            existing_position.avg_cost_basis = new_avg_cost
        else:
            new_position = Position(
                instrument_id=trade_event.instrument_id,
                quantity=new_quantity,
                avg_cost_basis=new_avg_cost,
                current_price=trade_event.executed_price,
            )
            portfolio.positions.append(new_position)

        # Update cash balance
        portfolio.cash_balance = portfolio.cash_balance + cash_delta
        portfolio.last_updated = datetime.now(timezone.utc)

        # Remove zero-quantity positions
        portfolio.positions = [p for p in portfolio.positions if p.quantity != Decimal("0")]

        # Recalculate portfolio metrics
        portfolio.calculate_total_value()
        portfolio.calculate_margin_available(MARGIN_RATIO)

        # Persist to DynamoDB
        self._persist_portfolio(portfolio)

        position_update = PositionUpdate(
            instrument_id=trade_event.instrument_id,
            previous_quantity=previous_quantity,
            new_quantity=new_quantity,
            previous_avg_cost=previous_avg_cost,
            new_avg_cost=new_avg_cost,
            cash_delta=cash_delta,
            trade_value=trade_event.trade_value,
        )

        metrics.add_metric(name="PositionUpdated", unit=MetricUnit.Count, value=1)
        metrics.add_metric(
            name="TradeValue",
            unit=MetricUnit.Count,
            value=float(trade_event.trade_value),
        )

        logger.info(
            "Position updated successfully",
            extra={
                "order_id": trade_event.order_id,
                "instrument_id": trade_event.instrument_id,
                "previous_quantity": str(previous_quantity),
                "new_quantity": str(new_quantity),
                "cash_delta": str(cash_delta),
            },
        )

        return position_update

    @tracer.capture_method
    def check_margin(self, client_id: str, order: OrderRequest) -> MarginResult:
        """Real-time margin validation for order acceptance.

        Validates that the client has sufficient margin to execute the proposed
        order. Considers:
        - Current available margin (cash + portfolio value * margin_ratio)
        - Required margin for the new order (Reg T: 50% of order value for buys)
        - Maintenance margin requirements (25% for existing positions)

        Args:
            client_id: Client placing the order.
            order: Proposed order to validate.

        Returns:
            MarginResult indicating APPROVED, REJECTED, or PENDING_REVIEW.
        """
        logger.info(
            "Performing margin check",
            extra={
                "client_id": client_id,
                "instrument_id": order.instrument_id,
                "side": order.side.value,
                "quantity": str(order.quantity),
                "order_value": str(order.order_value),
            },
        )

        # Retrieve current portfolio
        try:
            portfolio = self.get_portfolio(client_id, order.account_id)
        except NotFoundError:
            # No portfolio = no margin available
            return MarginResult(
                status=MarginStatus.REJECTED,
                available_margin=Decimal("0"),
                required_margin=order.order_value * MARGIN_RATIO,
                margin_after_trade=Decimal("0") - (order.order_value * MARGIN_RATIO),
                rejection_reason="No portfolio found for client",
                order_value=order.order_value,
            )

        available_margin = portfolio.margin_available

        # Calculate required margin based on order side
        if order.side == TradeSide.BUY:
            # Initial margin requirement: 50% of order value (Regulation T)
            required_margin = order.order_value * MARGIN_RATIO
        else:
            # Sell orders reduce exposure; margin requirement is lower
            # Only need maintenance margin for short sells
            existing_position = None
            for pos in portfolio.positions:
                if pos.instrument_id == order.instrument_id:
                    existing_position = pos
                    break

            if existing_position and order.quantity <= existing_position.quantity:
                # Closing or reducing existing long position - no margin needed
                required_margin = Decimal("0")
            else:
                # Short sell or selling more than owned
                short_quantity = order.quantity - (
                    existing_position.quantity if existing_position else Decimal("0")
                )
                required_margin = (
                    short_quantity * order.effective_price * MAINTENANCE_MARGIN_RATIO
                )

        margin_after_trade = available_margin - required_margin

        # Determine approval status
        if required_margin <= Decimal("0"):
            status = MarginStatus.APPROVED
            rejection_reason = None
        elif available_margin >= required_margin:
            status = MarginStatus.APPROVED
            rejection_reason = None
        elif margin_after_trade >= -(available_margin * Decimal("0.1")):
            # Within 10% tolerance - flag for review
            status = MarginStatus.PENDING_REVIEW
            rejection_reason = (
                f"Margin borderline: available={available_margin}, "
                f"required={required_margin}"
            )
        else:
            status = MarginStatus.REJECTED
            rejection_reason = (
                f"Insufficient margin: available={available_margin}, "
                f"required={required_margin}, shortfall={required_margin - available_margin}"
            )

        result = MarginResult(
            status=status,
            available_margin=available_margin,
            required_margin=required_margin,
            margin_after_trade=margin_after_trade,
            rejection_reason=rejection_reason,
            order_value=order.order_value,
        )

        metrics.add_metric(name="MarginCheckPerformed", unit=MetricUnit.Count, value=1)
        metrics.add_metric(
            name=f"MarginCheck{status.value.title()}",
            unit=MetricUnit.Count,
            value=1,
        )

        logger.info(
            "Margin check completed",
            extra={
                "client_id": client_id,
                "status": status.value,
                "available_margin": str(available_margin),
                "required_margin": str(required_margin),
            },
        )

        return result

    @tracer.capture_method
    def _persist_portfolio(self, portfolio: Portfolio) -> None:
        """Persist portfolio state to DynamoDB.

        Uses PutItem to write the full portfolio state. For high-concurrency
        scenarios, consider using conditional writes with version attributes.

        Args:
            portfolio: Portfolio object to persist.
        """
        item = {
            "client_id": portfolio.client_id,
            "account_id": portfolio.account_id,
            "cash_balance": portfolio.cash_balance,
            "positions": [p.to_dict() for p in portfolio.positions],
            "margin_available": portfolio.margin_available,
            "total_value": portfolio.total_value,
            "last_updated": portfolio.last_updated.isoformat(),
        }

        self._table.put_item(Item=item)

        logger.debug(
            "Portfolio persisted to DynamoDB",
            extra={
                "client_id": portfolio.client_id,
                "account_id": portfolio.account_id,
            },
        )


# --------------------------------------------------------------------------
# API Gateway Route Handlers
# --------------------------------------------------------------------------

# Shared service instance (created once per Lambda execution environment)
_wallet_service: WalletService | None = None


def _get_wallet_service() -> WalletService:
    """Get or create the shared WalletService instance."""
    global _wallet_service
    if _wallet_service is None:
        _wallet_service = WalletService()
    return _wallet_service


@app.get("/v1/portfolio/<client_id>")
@tracer.capture_method
def get_portfolio(client_id: str) -> dict[str, Any]:
    """GET /v1/portfolio/{client_id} - Retrieve portfolio positions and cash balance.

    Query Parameters:
        account_id (optional): Account identifier. Defaults to "default".

    Returns:
        JSON response with portfolio details including positions,
        cash balance, margin available, and total value.

    Raises:
        404: Portfolio not found for the given client/account.
    """
    account_id = app.current_event.get_query_string_value(
        name="account_id", default_value="default"
    )

    wallet_service = _get_wallet_service()
    portfolio = wallet_service.get_portfolio(client_id, account_id)

    return portfolio.to_dict()


@app.post("/v1/portfolio/<client_id>/margin-check")
@tracer.capture_method
def check_margin_endpoint(client_id: str) -> dict[str, Any]:
    """POST /v1/portfolio/{client_id}/margin-check - Validate margin for an order.

    Request Body:
        {
            "instrument_id": "string",
            "order_type": "MARKET|LIMIT|STOP|STOP_LIMIT",
            "side": "BUY|SELL",
            "quantity": "number",
            "limit_price": "number (optional)",
            "estimated_price": "number (optional)"
        }

    Returns:
        JSON response with margin check result including status,
        available margin, required margin, and rejection reason (if any).
    """
    body = app.current_event.json_body
    body["client_id"] = client_id
    if "account_id" not in body:
        body["account_id"] = app.current_event.get_query_string_value(
            name="account_id", default_value="default"
        )

    order = OrderRequest.from_dict(body)

    wallet_service = _get_wallet_service()
    result = wallet_service.check_margin(client_id, order)

    return result.to_dict()


# --------------------------------------------------------------------------
# SQS FIFO Event Processor (trade-processing.fifo queue)
# --------------------------------------------------------------------------


@tracer.capture_method
def process_sqs_trade_event(record: dict) -> dict[str, Any]:
    """Process a single trade.executed event from SQS FIFO queue.

    Parses the SQS message body as a trade event and updates the
    corresponding portfolio position.

    Args:
        record: SQS message record from event source mapping.

    Returns:
        Dictionary with processing result details.
    """
    message_body = json.loads(record["body"])

    logger.info(
        "Processing SQS trade event",
        extra={"message_id": record.get("messageId", "unknown")},
    )

    trade_event = TradeEvent.from_sqs_message(message_body)
    wallet_service = _get_wallet_service()
    position_update = wallet_service.update_position(trade_event)

    return {
        "status": "success",
        "order_id": trade_event.order_id,
        "position_update": position_update.to_dict(),
    }


# --------------------------------------------------------------------------
# Lambda Handler Entry Points
# --------------------------------------------------------------------------


@logger.inject_lambda_context(log_event=True)
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def lambda_handler(event: dict, context: LambdaContext) -> dict[str, Any]:
    """Main Lambda handler - routes API Gateway requests.

    This handler processes HTTP requests from API Gateway using the
    APIGatewayHttpResolver. Routes:
        GET /v1/portfolio/{client_id}
        POST /v1/portfolio/{client_id}/margin-check

    Args:
        event: API Gateway event payload.
        context: Lambda execution context.

    Returns:
        API Gateway response with status code and body.
    """
    return app.resolve(event, context)


@logger.inject_lambda_context(log_event=True)
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def sqs_handler(event: dict, context: LambdaContext) -> dict[str, Any]:
    """SQS FIFO handler - processes trade.executed events.

    Triggered by SQS event source mapping from trade-processing.fifo queue.
    Processes each trade event to update portfolio positions and cash balances.

    Uses batch item failure reporting to allow partial batch success.

    Args:
        event: SQS event with Records array.
        context: Lambda execution context.

    Returns:
        Dictionary with batchItemFailures for partial batch reporting.
    """
    records = event.get("Records", [])
    batch_item_failures: list[dict[str, str]] = []

    logger.info(
        "Processing SQS batch",
        extra={"record_count": len(records)},
    )

    for record in records:
        try:
            process_sqs_trade_event(record)
        except (KeyError, InvalidOperation, ValueError) as e:
            logger.error(
                "Failed to process trade event",
                extra={
                    "message_id": record.get("messageId", "unknown"),
                    "error": str(e),
                    "error_type": type(e).__name__,
                },
            )
            batch_item_failures.append(
                {"itemIdentifier": record["messageId"]}
            )
        except Exception as e:
            logger.exception(
                "Unexpected error processing trade event",
                extra={
                    "message_id": record.get("messageId", "unknown"),
                    "error": str(e),
                },
            )
            batch_item_failures.append(
                {"itemIdentifier": record["messageId"]}
            )

    metrics.add_metric(
        name="TradeEventsProcessed",
        unit=MetricUnit.Count,
        value=len(records) - len(batch_item_failures),
    )
    metrics.add_metric(
        name="TradeEventsFailed",
        unit=MetricUnit.Count,
        value=len(batch_item_failures),
    )

    logger.info(
        "SQS batch processing complete",
        extra={
            "total": len(records),
            "succeeded": len(records) - len(batch_item_failures),
            "failed": len(batch_item_failures),
        },
    )

    return {"batchItemFailures": batch_item_failures}
