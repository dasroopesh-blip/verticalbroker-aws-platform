"""Order Manager Lambda Handler.

Implements the Order Manager service for VerticalBroker's trading platform.
Provides RESTful endpoints for order submission and retrieval with:
- Idempotent order submission (DynamoDB persistence, 24h TTL)
- Pre-trade validation (margin, position limits, market hours, instrument)
- Transactional outbox pattern for trade.executed event emission
- Structured error handling with correlation IDs

Routes:
    POST /v1/orders       - Submit new order
    GET  /v1/orders/{id}  - Retrieve order by ID

Lambda Configuration:
    Reserved Concurrency: 1000
    Provisioned Concurrency: 200

Requirements: 7.1, 7.2, 7.5, 8.4
"""

from __future__ import annotations

import json
import os
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from typing import Any, Optional

import boto3
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.event_handler import (
    APIGatewayHttpResolver,
    Response,
    content_types,
)
from aws_lambda_powertools.event_handler.exceptions import (
    BadRequestError,
    NotFoundError,
)
from aws_lambda_powertools.logging import correlation_paths
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.idempotency import (
    DynamoDBPersistenceLayer,
    IdempotencyConfig,
    idempotent,
)
from aws_lambda_powertools.utilities.typing import LambdaContext

from src.services.order_manager.validation import (
    InstrumentNotFoundError,
    InsufficientMarginError,
    MarketClosedError,
    PositionLimitExceededError,
    ValidationError,
    check_margin,
    check_position_limits,
    validate_instrument,
    validate_market_hours,
    validate_order_fields,
)

# ---------------------------------------------------------------------------
# Lambda Powertools Configuration
# ---------------------------------------------------------------------------

logger = Logger(service="order-manager")
tracer = Tracer(service="order-manager")
metrics = Metrics(namespace="VerticalBroker/Orders")
app = APIGatewayHttpResolver()

# ---------------------------------------------------------------------------
# Idempotency Configuration (24h TTL)
# ---------------------------------------------------------------------------

IDEMPOTENCY_TABLE = os.environ.get("IDEMPOTENCY_TABLE", "IdempotencyStore")
ORDERS_TABLE = os.environ.get("ORDERS_TABLE", "Orders")
OUTBOX_TABLE = os.environ.get("OUTBOX_TABLE", "OrderOutbox")
EVENT_BUS_NAME = os.environ.get("EVENT_BUS_NAME", "verticalbroker-platform")

persistence_layer = DynamoDBPersistenceLayer(
    table_name=IDEMPOTENCY_TABLE,
    key_attr="idempotency_key",
    expiry_attr="expiration",
    status_attr="status",
    data_attr="data",
    in_progress_expiry_attr="in_progress_expiration",
)

idempotency_config = IdempotencyConfig(
    expires_after_seconds=86400,  # 24 hours TTL
    use_local_cache=True,
    local_cache_max_items=1000,
    event_key_jmespath="idempotency_key",
    raise_on_no_idempotency_key=True,
)


# ---------------------------------------------------------------------------
# Data Models
# ---------------------------------------------------------------------------


@dataclass
class OrderRequest:
    """Incoming order request from trading applications."""

    client_id: str
    account_id: str
    instrument_id: str  # ISIN/CUSIP
    order_type: str  # "MARKET" | "LIMIT" | "STOP" | "STOP_LIMIT"
    side: str  # "BUY" | "SELL"
    quantity: Decimal
    time_in_force: str  # "DAY" | "GTC" | "IOC" | "FOK"
    idempotency_key: str  # Client-provided dedup key
    limit_price: Optional[Decimal] = None
    stop_price: Optional[Decimal] = None

    @classmethod
    def from_dict(cls, data: dict) -> OrderRequest:
        """Create an OrderRequest from a raw dictionary.

        Args:
            data: Dictionary of order parameters from the API request body.

        Returns:
            Validated OrderRequest instance.

        Raises:
            ValidationError: If required fields are missing or invalid.
        """
        try:
            quantity = Decimal(str(data.get("quantity", "0")))
        except (InvalidOperation, TypeError, ValueError):
            raise ValidationError("quantity must be a valid number", field="quantity")

        limit_price = None
        if data.get("limit_price") is not None:
            try:
                limit_price = Decimal(str(data["limit_price"]))
            except (InvalidOperation, TypeError, ValueError):
                raise ValidationError(
                    "limit_price must be a valid number", field="limit_price"
                )

        stop_price = None
        if data.get("stop_price") is not None:
            try:
                stop_price = Decimal(str(data["stop_price"]))
            except (InvalidOperation, TypeError, ValueError):
                raise ValidationError(
                    "stop_price must be a valid number", field="stop_price"
                )

        return cls(
            client_id=str(data.get("client_id", "")),
            account_id=str(data.get("account_id", "")),
            instrument_id=str(data.get("instrument_id", "")),
            order_type=str(data.get("order_type", "")).upper(),
            side=str(data.get("side", "")).upper(),
            quantity=quantity,
            time_in_force=str(data.get("time_in_force", "")).upper(),
            idempotency_key=str(data.get("idempotency_key", "")),
            limit_price=limit_price,
            stop_price=stop_price,
        )


@dataclass
class OrderResponse:
    """Order execution response returned to clients."""

    order_id: str  # Platform-generated UUID
    status: str  # "ACCEPTED" | "REJECTED" | "PENDING"
    timestamp: str  # ISO-8601 datetime
    correlation_id: str  # For request tracing
    executed_price: Optional[str] = None
    executed_quantity: Optional[str] = None
    rejection_reason: Optional[str] = None

    def to_dict(self) -> dict:
        """Serialize to API response dictionary, excluding None values."""
        result = {
            "order_id": self.order_id,
            "status": self.status,
            "timestamp": self.timestamp,
            "correlation_id": self.correlation_id,
        }
        if self.executed_price is not None:
            result["executed_price"] = self.executed_price
        if self.executed_quantity is not None:
            result["executed_quantity"] = self.executed_quantity
        if self.rejection_reason is not None:
            result["rejection_reason"] = self.rejection_reason
        return result


# ---------------------------------------------------------------------------
# Order Manager Service Class
# ---------------------------------------------------------------------------


class OrderManager:
    """Handles order lifecycle: validation, execution, event emission.

    Implements:
        - Idempotent order submission with DynamoDB persistence (24h TTL)
        - Pre-trade validation: margin, position limits, market hours, instrument
        - Transactional writes: order record + outbox event atomically
        - Trade event emission via transactional outbox pattern

    Attributes:
        dynamodb: Boto3 DynamoDB resource.
        eventbridge: Boto3 EventBridge client.
        orders_table: DynamoDB Orders table reference.
    """

    def __init__(self):
        """Initialize DynamoDB and EventBridge clients."""
        self.dynamodb = boto3.resource("dynamodb")
        self.eventbridge = boto3.client("events")
        self.orders_table = self.dynamodb.Table(ORDERS_TABLE)
        self.outbox_table = self.dynamodb.Table(OUTBOX_TABLE)

    @tracer.capture_method
    def submit_order(self, request: OrderRequest) -> OrderResponse:
        """Submit a new order with full pre-trade validation and idempotency.

        Flow:
            1. Validate order fields
            2. Validate market hours
            3. Validate instrument exists and is tradeable
            4. Check margin sufficiency
            5. Check position limits
            6. Write order + outbox record atomically (transactional)
            7. Return OrderResponse

        The @idempotent decorator ensures duplicate submissions with the same
        idempotency_key return the cached response without re-executing.

        Args:
            request: Validated OrderRequest instance.

        Returns:
            OrderResponse with order status and execution details.
        """
        order_id = str(uuid.uuid4())
        correlation_id = tracer.get_trace_id() or str(uuid.uuid4())
        timestamp = datetime.now(timezone.utc)

        logger.info(
            "Processing order submission",
            extra={
                "order_id": order_id,
                "client_id": request.client_id,
                "instrument_id": request.instrument_id,
                "side": request.side,
                "quantity": str(request.quantity),
                "correlation_id": correlation_id,
            },
        )

        # ---- Pre-trade Validation ----

        # 1. Validate market hours
        market_result = validate_market_hours()
        if not market_result.is_valid:
            return self._create_rejected_response(
                order_id=order_id,
                correlation_id=correlation_id,
                timestamp=timestamp,
                reason="Market is closed",
            )

        # 2. Validate instrument exists
        validate_instrument(request.instrument_id)

        # 3. Check margin sufficiency
        check_margin(
            client_id=request.client_id,
            account_id=request.account_id,
            instrument_id=request.instrument_id,
            side=request.side,
            quantity=request.quantity,
            limit_price=request.limit_price,
        )

        # 4. Check position limits
        position_result = check_position_limits(
            client_id=request.client_id,
            account_id=request.account_id,
            instrument_id=request.instrument_id,
            side=request.side,
            quantity=request.quantity,
        )
        if not position_result.is_valid:
            return self._create_rejected_response(
                order_id=order_id,
                correlation_id=correlation_id,
                timestamp=timestamp,
                reason="Position limit exceeded",
            )

        # ---- Order Accepted - Write to DynamoDB ----
        metrics.add_metric(name="OrderAccepted", unit=MetricUnit.Count, value=1)

        # Write order + outbox record atomically using DynamoDB transact_write
        self._write_order_with_outbox(
            order_id=order_id,
            request=request,
            timestamp=timestamp,
            correlation_id=correlation_id,
        )

        logger.info(
            "Order accepted successfully",
            extra={"order_id": order_id, "correlation_id": correlation_id},
        )

        return OrderResponse(
            order_id=order_id,
            status="ACCEPTED",
            timestamp=timestamp.isoformat(),
            correlation_id=correlation_id,
            executed_quantity=str(request.quantity),
        )

    @tracer.capture_method
    def get_order(self, order_id: str) -> OrderResponse:
        """Retrieve an existing order by ID.

        Args:
            order_id: Platform-generated UUID for the order.

        Returns:
            OrderResponse with current order state.

        Raises:
            NotFoundError: If order does not exist.
        """
        try:
            response = self.orders_table.get_item(Key={"order_id": order_id})
            item = response.get("Item")

            if not item:
                raise NotFoundError(f"Order not found: {order_id}")

            return OrderResponse(
                order_id=item["order_id"],
                status=item["status"],
                timestamp=item["timestamp"],
                correlation_id=item.get("correlation_id", ""),
                executed_price=item.get("executed_price"),
                executed_quantity=item.get("executed_quantity"),
                rejection_reason=item.get("rejection_reason"),
            )

        except NotFoundError:
            raise
        except Exception as e:
            logger.error(f"Error retrieving order {order_id}: {e}")
            raise

    @tracer.capture_method
    def emit_trade_event(self, order_id: str, request: OrderRequest, timestamp: datetime):
        """Publish trade.executed event to EventBridge.

        This is called by DynamoDB Streams processor when it detects new outbox
        records, implementing the transactional outbox pattern. The event is
        emitted only after the order and outbox record are committed atomically.

        Args:
            order_id: Platform-generated order UUID.
            request: Original order request.
            timestamp: Order execution timestamp.
        """
        event_detail = {
            "order_id": order_id,
            "client_id": request.client_id,
            "account_id": request.account_id,
            "instrument_id": request.instrument_id,
            "side": request.side,
            "quantity": str(request.quantity),
            "order_type": request.order_type,
            "time_in_force": request.time_in_force,
            "execution_timestamp": timestamp.isoformat(),
        }

        if request.limit_price is not None:
            event_detail["executed_price"] = str(request.limit_price)

        try:
            self.eventbridge.put_events(
                Entries=[
                    {
                        "Source": "verticalbroker.order-manager",
                        "DetailType": "TradeExecuted",
                        "Detail": json.dumps(event_detail, default=str),
                        "EventBusName": EVENT_BUS_NAME,
                    }
                ]
            )
            logger.info(
                "Trade event emitted",
                extra={"order_id": order_id, "event_bus": EVENT_BUS_NAME},
            )
            metrics.add_metric(name="TradeEventEmitted", unit=MetricUnit.Count, value=1)
        except Exception as e:
            logger.error(
                f"Failed to emit trade event for order {order_id}: {e}",
                extra={"order_id": order_id},
            )
            metrics.add_metric(
                name="TradeEventEmitFailed", unit=MetricUnit.Count, value=1
            )
            raise

    # ------------------------------------------------------------------
    # Private Methods
    # ------------------------------------------------------------------

    @tracer.capture_method
    def _write_order_with_outbox(
        self,
        order_id: str,
        request: OrderRequest,
        timestamp: datetime,
        correlation_id: str,
    ) -> None:
        """Atomically write order record and outbox event using DynamoDB TransactWriteItems.

        This implements the transactional outbox pattern:
        - Order record written to Orders table
        - Outbox event record written to OrderOutbox table
        - DynamoDB Streams on OrderOutbox publishes events to EventBridge

        Both writes succeed or both fail, ensuring consistency between
        order state and event emission.

        Args:
            order_id: Platform-generated UUID.
            request: Validated order request.
            timestamp: Execution timestamp.
            correlation_id: Distributed tracing correlation ID.
        """
        dynamodb_client = boto3.client("dynamodb")

        order_item = {
            "order_id": {"S": order_id},
            "client_id": {"S": request.client_id},
            "account_id": {"S": request.account_id},
            "instrument_id": {"S": request.instrument_id},
            "order_type": {"S": request.order_type},
            "side": {"S": request.side},
            "quantity": {"N": str(request.quantity)},
            "time_in_force": {"S": request.time_in_force},
            "idempotency_key": {"S": request.idempotency_key},
            "status": {"S": "ACCEPTED"},
            "timestamp": {"S": timestamp.isoformat()},
            "correlation_id": {"S": correlation_id},
        }

        if request.limit_price is not None:
            order_item["limit_price"] = {"N": str(request.limit_price)}
        if request.stop_price is not None:
            order_item["stop_price"] = {"N": str(request.stop_price)}

        # Outbox record for DynamoDB Streams -> EventBridge
        outbox_item = {
            "event_id": {"S": str(uuid.uuid4())},
            "order_id": {"S": order_id},
            "event_type": {"S": "trade.executed"},
            "source": {"S": "verticalbroker.order-manager"},
            "detail_type": {"S": "TradeExecuted"},
            "payload": {
                "S": json.dumps(
                    {
                        "order_id": order_id,
                        "client_id": request.client_id,
                        "account_id": request.account_id,
                        "instrument_id": request.instrument_id,
                        "side": request.side,
                        "quantity": str(request.quantity),
                        "order_type": request.order_type,
                        "time_in_force": request.time_in_force,
                        "execution_timestamp": timestamp.isoformat(),
                        "correlation_id": correlation_id,
                    },
                    default=str,
                )
            },
            "status": {"S": "PENDING"},
            "created_at": {"S": timestamp.isoformat()},
            "ttl": {"N": str(int(timestamp.timestamp()) + 86400)},  # 24h TTL
        }

        try:
            dynamodb_client.transact_write_items(
                TransactItems=[
                    {
                        "Put": {
                            "TableName": ORDERS_TABLE,
                            "Item": order_item,
                            "ConditionExpression": "attribute_not_exists(order_id)",
                        }
                    },
                    {
                        "Put": {
                            "TableName": OUTBOX_TABLE,
                            "Item": outbox_item,
                        }
                    },
                ]
            )
            logger.info(
                "Order and outbox record written atomically",
                extra={"order_id": order_id},
            )
        except dynamodb_client.exceptions.TransactionCanceledException as e:
            logger.error(
                f"Transaction cancelled for order {order_id}: {e}",
                extra={"order_id": order_id},
            )
            raise
        except Exception as e:
            logger.error(
                f"Error writing order transaction: {e}",
                extra={"order_id": order_id},
            )
            raise

    def _create_rejected_response(
        self,
        order_id: str,
        correlation_id: str,
        timestamp: datetime,
        reason: str,
    ) -> OrderResponse:
        """Create a rejected order response and record metrics.

        Args:
            order_id: Platform-generated UUID.
            correlation_id: Distributed tracing correlation ID.
            timestamp: Rejection timestamp.
            reason: Human-readable rejection reason.

        Returns:
            OrderResponse with REJECTED status.
        """
        metrics.add_metric(name="OrderRejected", unit=MetricUnit.Count, value=1)
        logger.info(
            "Order rejected",
            extra={
                "order_id": order_id,
                "reason": reason,
                "correlation_id": correlation_id,
            },
        )

        return OrderResponse(
            order_id=order_id,
            status="REJECTED",
            timestamp=timestamp.isoformat(),
            correlation_id=correlation_id,
            rejection_reason=reason,
        )


# ---------------------------------------------------------------------------
# Singleton instance
# ---------------------------------------------------------------------------

order_manager = OrderManager()


# ---------------------------------------------------------------------------
# API Routes
# ---------------------------------------------------------------------------


@app.post("/v1/orders")
@tracer.capture_method
def create_order():
    """POST /v1/orders - Submit a new order.

    Request body must include:
        - client_id, account_id, instrument_id
        - order_type (MARKET|LIMIT|STOP|STOP_LIMIT)
        - side (BUY|SELL)
        - quantity (positive number)
        - time_in_force (DAY|GTC|IOC|FOK)
        - idempotency_key (client-provided dedup key)

    Optional fields:
        - limit_price (required for LIMIT/STOP_LIMIT)
        - stop_price (required for STOP/STOP_LIMIT)

    Returns:
        201: OrderResponse with order_id, status, timestamp, correlation_id
        400: ValidationError details
        404: Instrument not found
        422: Insufficient margin
    """
    body = app.current_event.json_body

    # Step 1: Validate order fields
    validation_result = validate_order_fields(body)
    if not validation_result.is_valid:
        issues = [
            {"field": issue.field, "message": issue.message}
            for issue in validation_result.issues
        ]
        return Response(
            status_code=400,
            content_type=content_types.APPLICATION_JSON,
            body=json.dumps(
                {
                    "error": "ValidationError",
                    "message": "Order validation failed",
                    "details": issues,
                    "correlation_id": tracer.get_trace_id() or "",
                }
            ),
        )

    # Step 2: Parse into typed OrderRequest
    try:
        order_request = OrderRequest.from_dict(body)
    except ValidationError as e:
        return Response(
            status_code=400,
            content_type=content_types.APPLICATION_JSON,
            body=json.dumps(
                {
                    "error": "ValidationError",
                    "message": e.message,
                    "field": e.field,
                    "correlation_id": tracer.get_trace_id() or "",
                }
            ),
        )

    # Step 3: Submit order (includes pre-trade validation)
    try:
        response = order_manager.submit_order(order_request)
        return Response(
            status_code=201,
            content_type=content_types.APPLICATION_JSON,
            body=json.dumps(response.to_dict()),
        )
    except InstrumentNotFoundError as e:
        metrics.add_metric(
            name="InstrumentNotFound", unit=MetricUnit.Count, value=1
        )
        return Response(
            status_code=404,
            content_type=content_types.APPLICATION_JSON,
            body=json.dumps(
                {
                    "error": "InstrumentNotFound",
                    "message": e.message,
                    "instrument_id": e.instrument_id,
                    "correlation_id": tracer.get_trace_id() or "",
                }
            ),
        )
    except InsufficientMarginError as e:
        metrics.add_metric(
            name="InsufficientMargin", unit=MetricUnit.Count, value=1
        )
        return Response(
            status_code=422,
            content_type=content_types.APPLICATION_JSON,
            body=json.dumps(
                {
                    "error": "InsufficientMargin",
                    "message": e.message,
                    "required_margin": str(e.required_margin),
                    "available_margin": str(e.available_margin),
                    "account_id": e.account_id,
                    "correlation_id": tracer.get_trace_id() or "",
                }
            ),
        )
    except PositionLimitExceededError as e:
        metrics.add_metric(
            name="PositionLimitExceeded", unit=MetricUnit.Count, value=1
        )
        return Response(
            status_code=422,
            content_type=content_types.APPLICATION_JSON,
            body=json.dumps(
                {
                    "error": "PositionLimitExceeded",
                    "message": e.message,
                    "instrument_id": e.instrument_id,
                    "correlation_id": tracer.get_trace_id() or "",
                }
            ),
        )
    except Exception as e:
        logger.exception("Unexpected error processing order")
        metrics.add_metric(name="OrderError", unit=MetricUnit.Count, value=1)
        return Response(
            status_code=500,
            content_type=content_types.APPLICATION_JSON,
            body=json.dumps(
                {
                    "error": "InternalError",
                    "message": "An unexpected error occurred",
                    "correlation_id": tracer.get_trace_id() or "",
                }
            ),
        )


@app.get("/v1/orders/<order_id>")
@tracer.capture_method
def get_order(order_id: str):
    """GET /v1/orders/{order_id} - Retrieve order by ID.

    Path Parameters:
        order_id: Platform-generated UUID for the order.

    Returns:
        200: OrderResponse with current order state
        404: Order not found
    """
    try:
        response = order_manager.get_order(order_id)
        return Response(
            status_code=200,
            content_type=content_types.APPLICATION_JSON,
            body=json.dumps(response.to_dict()),
        )
    except NotFoundError as e:
        return Response(
            status_code=404,
            content_type=content_types.APPLICATION_JSON,
            body=json.dumps(
                {
                    "error": "NotFound",
                    "message": str(e),
                    "order_id": order_id,
                    "correlation_id": tracer.get_trace_id() or "",
                }
            ),
        )
    except Exception as e:
        logger.exception(f"Error retrieving order {order_id}")
        return Response(
            status_code=500,
            content_type=content_types.APPLICATION_JSON,
            body=json.dumps(
                {
                    "error": "InternalError",
                    "message": "An unexpected error occurred",
                    "correlation_id": tracer.get_trace_id() or "",
                }
            ),
        )


# ---------------------------------------------------------------------------
# Lambda Entry Point
# ---------------------------------------------------------------------------


@logger.inject_lambda_context(correlation_id_path=correlation_paths.API_GATEWAY_HTTP)
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
@idempotent(
    persistence_store=persistence_layer,
    config=idempotency_config,
)
def lambda_handler(event: dict, context: LambdaContext) -> dict:
    """Lambda entry point for Order Manager service.

    Configured with:
        - Lambda Powertools Logger (structured JSON logging)
        - Lambda Powertools Tracer (X-Ray distributed tracing)
        - Lambda Powertools Metrics (CloudWatch EMF metrics)
        - Idempotency decorator (DynamoDB-backed, 24h TTL)
        - APIGatewayHttpResolver for route handling

    Reserved Concurrency: 1000
    Provisioned Concurrency: 200

    Args:
        event: API Gateway HTTP API event payload.
        context: Lambda execution context.

    Returns:
        API Gateway HTTP API response dictionary.
    """
    return app.resolve(event, context)
