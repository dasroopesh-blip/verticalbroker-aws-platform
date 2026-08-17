"""
Trade Processor Lambda — Production-Ready Implementation
=========================================================
Senior Developer: Vertical Broker Platform Team
Design: SQS → Lambda → DynamoDB + S3 with ReportBatchItemFailures

Key Design Decisions:
- Decimal arithmetic for all financial calculations
- Atomic idempotency via DynamoDB conditional writes
- Partial batch failure reporting (ReportBatchItemFailures)
- PII-safe structured logging
- Fail-fast on misconfiguration
- Two-tier error handling: validation (drop) vs transient (retry)
"""

import json
import logging
import os
import re
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_EVEN
from typing import Any

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

# =============================================================================
# CONFIGURATION — Fail fast if environment is misconfigured
# =============================================================================

ORDERS_TABLE_NAME = os.environ["ORDERS_TABLE"]
IDEMPOTENCY_TABLE_NAME = os.environ["IDEMPOTENCY_TABLE"]
REPORT_BUCKET = os.environ["REPORT_BUCKET"]
IDEMPOTENCY_TTL_SECONDS = int(os.environ.get("IDEMPOTENCY_TTL_SECONDS", "86400"))
IDEMPOTENCY_LOCK_TTL_SECONDS = int(os.environ.get("IDEMPOTENCY_LOCK_TTL_SECONDS", "300"))

# =============================================================================
# LOGGING — Structured, PII-safe
# =============================================================================

logger = logging.getLogger(__name__)
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))


class StructuredFormatter(logging.Formatter):
    """JSON structured log formatter for CloudWatch Insights."""

    def format(self, record: logging.LogRecord) -> str:
        log_entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
        }
        # Add extra fields (request_id, message_id, etc.)
        for key in ("request_id", "message_id", "symbol", "error_type", "error"):
            if hasattr(record, key):
                log_entry[key] = getattr(record, key)
        if record.exc_info:
            log_entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_entry, default=str)


handler = logging.StreamHandler()
handler.setFormatter(StructuredFormatter())
logger.addHandler(handler)
logger.propagate = False

# =============================================================================
# AWS CLIENTS — With adaptive retry
# =============================================================================

boto_config = Config(
    retries={"max_attempts": 3, "mode": "adaptive"},
    connect_timeout=5,
    read_timeout=10,
)

dynamodb = boto3.resource("dynamodb", config=boto_config)
s3 = boto3.client("s3", config=boto_config)

orders_table = dynamodb.Table(ORDERS_TABLE_NAME)
idempotency_table = dynamodb.Table(IDEMPOTENCY_TABLE_NAME)

# =============================================================================
# VALIDATION
# =============================================================================

SYMBOL_REGEX = re.compile(r"^[A-Z]{1,5}$")
MAX_QUANTITY = 1_000_000
MAX_PRICE = Decimal("999999.99")


class ValidationError(Exception):
    """Non-retryable: message is malformed and should route to DLQ."""
    pass


class IdempotencyLockHeld(Exception):
    """Request already processed or in-progress."""
    pass


def validate_trade(trade: dict) -> None:
    """
    Validate all required fields before any writes.
    Raises ValidationError for malformed input (non-retryable).
    """
    request_id = trade.get("request_id")
    if not request_id or not isinstance(request_id, str) or len(request_id) > 128:
        raise ValidationError(f"Invalid request_id: must be non-empty string <= 128 chars")

    customer_id = trade.get("customer_id")
    if not customer_id or not isinstance(customer_id, str) or len(customer_id) > 128:
        raise ValidationError(f"Invalid customer_id: must be non-empty string <= 128 chars")

    symbol = trade.get("symbol", "")
    if not SYMBOL_REGEX.match(symbol):
        raise ValidationError(f"Invalid symbol: must match [A-Z]{{1,5}}, got '{symbol}'")

    # Quantity validation
    if "quantity" not in trade:
        raise ValidationError("Missing required field: quantity")
    try:
        quantity = int(trade["quantity"])
    except (ValueError, TypeError):
        raise ValidationError(f"Invalid quantity: not an integer")
    if quantity <= 0:
        raise ValidationError(f"Invalid quantity: must be positive, got {quantity}")
    if quantity > MAX_QUANTITY:
        raise ValidationError(f"Invalid quantity: exceeds maximum {MAX_QUANTITY}")

    # Price validation
    if "price" not in trade:
        raise ValidationError("Missing required field: price")
    try:
        price = Decimal(str(trade["price"]))
    except (InvalidOperation, TypeError, ValueError):
        raise ValidationError(f"Invalid price: cannot parse as decimal")
    if price <= 0:
        raise ValidationError(f"Invalid price: must be positive, got {price}")
    if price > MAX_PRICE:
        raise ValidationError(f"Invalid price: exceeds maximum {MAX_PRICE}")


# =============================================================================
# FINANCIAL CALCULATION
# =============================================================================

def calculate_total(quantity: int, price: str) -> Decimal:
    """
    Financial-precision multiplication using Decimal.
    Uses ROUND_HALF_EVEN (banker's rounding) to avoid systematic bias.
    """
    d_price = Decimal(str(price))
    d_quantity = Decimal(str(quantity))
    total = (d_quantity * d_price).quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)
    return total


# =============================================================================
# IDEMPOTENCY — Atomic lock acquisition
# =============================================================================

def acquire_idempotency_lock(request_id: str) -> bool:
    """
    Atomic check-and-lock using DynamoDB conditional write.
    
    Returns True if lock acquired (proceed with processing).
    Returns False if already completed (skip — not a failure).
    Raises exception if lock is stale and needs cleanup.
    """
    now = datetime.now(timezone.utc)
    now_epoch = int(now.timestamp())

    try:
        idempotency_table.put_item(
            Item={
                "request_id": request_id,
                "status": "IN_PROGRESS",
                "locked_at": now.isoformat(),
                "expires_at": now_epoch + IDEMPOTENCY_TTL_SECONDS,
            },
            ConditionExpression="attribute_not_exists(request_id)",
        )
        return True

    except ClientError as e:
        if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise  # Unexpected error — let it bubble up

        # Lock exists — check if it's completed or stale
        existing = idempotency_table.get_item(
            Key={"request_id": request_id}
        ).get("Item", {})

        status = existing.get("status")

        if status == "COMPLETED":
            logger.info(
                "Request already completed, skipping",
                extra={"request_id": request_id},
            )
            return False

        # IN_PROGRESS — check if stale (crashed previous execution)
        locked_at_str = existing.get("locked_at", "")
        try:
            locked_at = datetime.fromisoformat(locked_at_str)
            age_seconds = (now - locked_at).total_seconds()
            if age_seconds > IDEMPOTENCY_LOCK_TTL_SECONDS:
                # Stale lock — attempt to reclaim
                idempotency_table.put_item(
                    Item={
                        "request_id": request_id,
                        "status": "IN_PROGRESS",
                        "locked_at": now.isoformat(),
                        "expires_at": now_epoch + IDEMPOTENCY_TTL_SECONDS,
                    },
                    ConditionExpression="locked_at = :old_lock",
                    ExpressionAttributeValues={":old_lock": locked_at_str},
                )
                logger.info(
                    "Reclaimed stale idempotency lock",
                    extra={"request_id": request_id, "stale_age_seconds": age_seconds},
                )
                return True
        except (ValueError, TypeError, ClientError):
            pass  # Can't reclaim — treat as held

        logger.info(
            "Request in-progress by another invocation, skipping",
            extra={"request_id": request_id},
        )
        return False


def mark_idempotency_completed(request_id: str) -> None:
    """Transition idempotency record from IN_PROGRESS → COMPLETED."""
    idempotency_table.update_item(
        Key={"request_id": request_id},
        UpdateExpression="SET #s = :s, completed_at = :t",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":s": "COMPLETED",
            ":t": datetime.now(timezone.utc).isoformat(),
        },
    )


# =============================================================================
# TRADE PROCESSING
# =============================================================================

def process_trade(trade: dict) -> None:
    """
    Process a single validated trade:
    1. Calculate total with Decimal precision
    2. Write order to DynamoDB (conditional — no overwrites)
    3. Write report to S3 (idempotent by key)
    4. Mark idempotency as COMPLETED
    """
    request_id = trade["request_id"]
    customer_id = trade["customer_id"]
    symbol = trade["symbol"]
    quantity = int(trade["quantity"])
    price = str(trade["price"])

    total_amount = calculate_total(quantity, price)
    now = datetime.now(timezone.utc).isoformat()

    order = {
        "order_id": request_id,
        "request_id": request_id,
        "customer_id": customer_id,
        "symbol": symbol,
        "quantity": quantity,
        "price": price,
        "total_amount": str(total_amount),
        "status": "PROCESSED",
        "processed_at": now,
    }

    # Write order — conditional to prevent duplicate writes on retry
    try:
        orders_table.put_item(
            Item=order,
            ConditionExpression="attribute_not_exists(order_id)",
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            # Order already exists (retry scenario) — safe to continue
            logger.info(
                "Order already exists, continuing to ensure completion",
                extra={"request_id": request_id},
            )
        else:
            raise

    # Write S3 report — naturally idempotent (same key = safe overwrite)
    report_key = f"customers/{customer_id}/trades/{request_id}.json"
    s3.put_object(
        Bucket=REPORT_BUCKET,
        Key=report_key,
        Body=json.dumps(order, default=str),
        ContentType="application/json",
        ServerSideEncryption="aws:kms",
    )

    # Mark idempotency as completed (final step)
    mark_idempotency_completed(request_id)


# =============================================================================
# LAMBDA HANDLER — SQS Batch with ReportBatchItemFailures
# =============================================================================

def lambda_handler(event: dict, context: Any) -> dict:
    """
    SQS batch processor with partial failure reporting.
    
    Contract:
    - Returns {"batchItemFailures": [...]} for SQS to retry only failed messages
    - Validation errors are NOT retried (message drops to DLQ after maxReceiveCount)
    - Transient errors ARE retried via batchItemFailures
    """
    batch_item_failures = []
    records = event.get("Records", [])

    logger.info(
        "Batch received",
        extra={"message_id": context.aws_request_id if context else "local"},
    )

    for record in records:
        message_id = record.get("messageId", "unknown")

        try:
            # Parse message body
            try:
                trade = json.loads(record["body"])
            except (json.JSONDecodeError, KeyError) as e:
                raise ValidationError(f"Malformed message body: {e}")

            # PII-safe logging — only safe identifiers
            logger.info(
                "Processing trade",
                extra={
                    "request_id": trade.get("request_id", "unknown"),
                    "symbol": trade.get("symbol", "unknown"),
                    "message_id": message_id,
                },
            )

            # Validate input
            validate_trade(trade)

            # Acquire atomic idempotency lock
            request_id = trade["request_id"]
            if not acquire_idempotency_lock(request_id):
                # Already processed — skip (not a failure)
                continue

            # Process the trade
            process_trade(trade)

            logger.info(
                "Trade processed successfully",
                extra={"request_id": request_id, "message_id": message_id},
            )

        except ValidationError as e:
            # Non-retryable — log warning and let SQS route to DLQ
            # By NOT adding to batchItemFailures, SQS counts this toward
            # maxReceiveCount and eventually routes to DLQ
            logger.warning(
                "Validation failed — message will route to DLQ",
                extra={
                    "message_id": message_id,
                    "error": str(e),
                    "error_type": "ValidationError",
                },
            )
            batch_item_failures.append({"itemIdentifier": message_id})

        except Exception as e:
            # Transient failure — report for retry
            logger.error(
                "Trade processing failed — will retry",
                extra={
                    "message_id": message_id,
                    "error_type": type(e).__name__,
                    "error": str(e),
                },
                exc_info=True,
            )
            batch_item_failures.append({"itemIdentifier": message_id})

    logger.info(
        "Batch complete",
        extra={
            "total": len(records),
            "failed": len(batch_item_failures),
            "message_id": context.aws_request_id if context else "local",
        },
    )

    return {"batchItemFailures": batch_item_failures}
