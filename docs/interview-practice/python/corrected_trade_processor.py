"""
Trade Processor Lambda — Corrected Version
============================================
This is the junior developer's code rewritten to fix all 14 identified issues.
Each fix is annotated with the Finding # it addresses.

Changes from junior code:
  Finding #1  → ReportBatchItemFailures return format
  Finding #2  → Atomic idempotency via conditional put_item
  Finding #3  → Decimal arithmetic for money
  Finding #4  → PII-safe structured logging
  Finding #5  → Input validation before processing
  Finding #6  → Correct SQS return contract
  Finding #7  → Reordered writes (lock → order → S3 → complete)
  Finding #8  → Adaptive retry on boto3 clients
  Finding #9  → timezone-aware datetime
  Finding #10 → Fail-fast env vars (no prod defaults)
  Finding #11 → Conditional write on orders table
  Finding #12 → Integer TTL
  Finding #13 → Structured JSON logging with correlation IDs
  Finding #14 → S3 encryption + content type
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
# FIX #10: Fail fast — no hardcoded production defaults
# Before: os.environ.get("ORDERS_TABLE", "verticalbroker-prod-orders")
# After:  os.environ["ORDERS_TABLE"]  → KeyError immediately if missing
# =============================================================================

ORDERS_TABLE_NAME = os.environ["ORDERS_TABLE"]
IDEMPOTENCY_TABLE_NAME = os.environ["IDEMPOTENCY_TABLE"]
REPORT_BUCKET = os.environ["REPORT_BUCKET"]
IDEMPOTENCY_TTL_SECONDS = int(os.environ.get("IDEMPOTENCY_TTL_SECONDS", "86400"))
LOCK_STALENESS_SECONDS = int(os.environ.get("LOCK_STALENESS_SECONDS", "300"))


# =============================================================================
# FIX #13: Structured JSON logging (replaces bare print statements)
# Before: print(f"Processing customer trade: {trade}")
# After:  logger.info("Processing trade", extra={"request_id": ..., "symbol": ...})
# =============================================================================

logger = logging.getLogger(__name__)
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))


class StructuredFormatter(logging.Formatter):
    """Outputs logs as JSON for CloudWatch Insights queryability."""

    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "message": record.getMessage(),
        }
        for field in ("request_id", "message_id", "symbol", "error_type",
                      "error", "total", "failed", "stale_age"):
            if hasattr(record, field):
                entry[field] = getattr(record, field)
        if record.exc_info:
            entry["stacktrace"] = self.formatException(record.exc_info)
        return json.dumps(entry, default=str)


_handler = logging.StreamHandler()
_handler.setFormatter(StructuredFormatter())
logger.addHandler(_handler)
logger.propagate = False


# =============================================================================
# FIX #8: Adaptive retry with backoff on all AWS SDK calls
# Before: boto3.resource("dynamodb") — bare, minimal default retry
# After:  explicit adaptive retry with timeouts
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
# FIX #5: Input validation — reject malformed data before any writes
# Before: No validation at all. None, 0, negative values all accepted.
# After:  Strict checks on every field with clear error messages.
# =============================================================================

SYMBOL_REGEX = re.compile(r"^[A-Z]{1,5}$")
MAX_QUANTITY = 1_000_000
MAX_PRICE = Decimal("999999.99")


class ValidationError(Exception):
    """Non-retryable input error. Message should route to DLQ."""
    pass


def validate_trade(trade: dict) -> None:
    """Validate all fields. Raises ValidationError if malformed."""

    request_id = trade.get("request_id")
    if not request_id or not isinstance(request_id, str) or len(request_id) > 128:
        raise ValidationError("Invalid or missing request_id")

    customer_id = trade.get("customer_id")
    if not customer_id or not isinstance(customer_id, str) or len(customer_id) > 128:
        raise ValidationError("Invalid or missing customer_id")

    symbol = trade.get("symbol", "")
    if not SYMBOL_REGEX.match(symbol):
        raise ValidationError(f"Invalid symbol format: '{symbol}'")

    if "quantity" not in trade:
        raise ValidationError("Missing required field: quantity")
    try:
        qty = int(trade["quantity"])
    except (ValueError, TypeError):
        raise ValidationError("Quantity is not a valid integer")
    if qty <= 0:
        raise ValidationError(f"Quantity must be positive, got {qty}")
    if qty > MAX_QUANTITY:
        raise ValidationError(f"Quantity exceeds max allowed: {qty}")

    if "price" not in trade:
        raise ValidationError("Missing required field: price")
    try:
        px = Decimal(str(trade["price"]))
    except (InvalidOperation, TypeError, ValueError):
        raise ValidationError("Price is not a valid decimal number")
    if px <= 0:
        raise ValidationError(f"Price must be positive, got {px}")
    if px > MAX_PRICE:
        raise ValidationError(f"Price exceeds max allowed: {px}")


# =============================================================================
# FIX #3: Financial-precision calculation using Decimal
# Before: total_amount = round(quantity * price, 2)  ← float math!
# After:  Decimal with ROUND_HALF_EVEN (banker's rounding)
# =============================================================================

def calculate_total(quantity: int, price: str) -> Decimal:
    """Multiply quantity × price with exact decimal precision."""
    d_price = Decimal(str(price))
    d_quantity = Decimal(str(quantity))
    return (d_quantity * d_price).quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)


# =============================================================================
# FIX #2: Atomic idempotency — conditional write replaces get-then-put
# Before: get_item → check → put_item (RACE CONDITION!)
# After:  Single put_item with ConditionExpression (atomic)
# =============================================================================

def acquire_idempotency_lock(request_id: str) -> bool:
    """
    Atomically acquire processing lock.
    Returns True  → lock acquired, proceed with processing.
    Returns False → already processed or in-progress, skip.
    """
    now = datetime.now(timezone.utc)
    now_epoch = int(now.timestamp())

    try:
        idempotency_table.put_item(
            Item={
                "request_id": request_id,
                "status": "IN_PROGRESS",
                "locked_at": now.isoformat(),
                "expires_at": now_epoch + IDEMPOTENCY_TTL_SECONDS,  # FIX #12: int, not float
            },
            ConditionExpression="attribute_not_exists(request_id)",
        )
        return True

    except ClientError as e:
        if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise  # Unexpected error — bubble up for retry

        # Record exists — check if completed or stale
        existing = idempotency_table.get_item(
            Key={"request_id": request_id}
        ).get("Item", {})

        if existing.get("status") == "COMPLETED":
            logger.info("Already completed, skipping", extra={"request_id": request_id})
            return False

        # Check for stale IN_PROGRESS lock (crashed Lambda)
        locked_at_str = existing.get("locked_at", "")
        try:
            locked_at = datetime.fromisoformat(locked_at_str)
            age = (now - locked_at).total_seconds()
            if age > LOCK_STALENESS_SECONDS:
                # Reclaim stale lock with conditional overwrite
                idempotency_table.put_item(
                    Item={
                        "request_id": request_id,
                        "status": "IN_PROGRESS",
                        "locked_at": now.isoformat(),
                        "expires_at": now_epoch + IDEMPOTENCY_TTL_SECONDS,
                    },
                    ConditionExpression="locked_at = :old",
                    ExpressionAttributeValues={":old": locked_at_str},
                )
                logger.info("Reclaimed stale lock", extra={
                    "request_id": request_id, "stale_age": int(age)
                })
                return True
        except (ValueError, TypeError, ClientError):
            pass

        logger.info("In-progress by another invocation", extra={"request_id": request_id})
        return False


def mark_completed(request_id: str) -> None:
    """Transition idempotency: IN_PROGRESS → COMPLETED."""
    idempotency_table.update_item(
        Key={"request_id": request_id},
        UpdateExpression="SET #s = :s, completed_at = :t",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":s": "COMPLETED",
            # FIX #9: timezone-aware datetime
            ":t": datetime.now(timezone.utc).isoformat(),
        },
    )


# =============================================================================
# FIX #7 + #11 + #14: Correct write ordering with conditional + encryption
# Before: Unconditional put → S3 (no encryption) → idempotency last
# After:  Lock first → conditional order write → encrypted S3 → mark complete
# =============================================================================

def process_trade(trade: dict) -> None:
    """Process a single validated trade with correct write ordering."""

    request_id = trade["request_id"]
    customer_id = trade["customer_id"]
    symbol = trade["symbol"]
    quantity = int(trade["quantity"])
    price = str(trade["price"])

    # FIX #3: Decimal calculation
    total_amount = calculate_total(quantity, price)

    # FIX #9: Timezone-aware timestamp
    now = datetime.now(timezone.utc).isoformat()

    order = {
        "order_id": request_id,
        "request_id": request_id,
        "customer_id": customer_id,
        "symbol": symbol,
        "quantity": quantity,
        "price": price,                    # String, not float — preserves precision
        "total_amount": str(total_amount), # String Decimal — exact value
        "status": "PROCESSED",
        "processed_at": now,               # Timezone-aware ISO 8601
    }

    # FIX #11: Conditional write — prevent overwrites on retry
    try:
        orders_table.put_item(
            Item=order,
            ConditionExpression="attribute_not_exists(order_id)",
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            # Already exists (retry path) — safe to continue
            logger.info("Order already exists, ensuring completion",
                        extra={"request_id": request_id})
        else:
            raise

    # FIX #14: S3 with encryption and content type
    # S3 is naturally idempotent (same key = safe overwrite)
    report_key = f"customers/{customer_id}/trades/{request_id}.json"
    s3.put_object(
        Bucket=REPORT_BUCKET,
        Key=report_key,
        Body=json.dumps(order, default=str),
        ContentType="application/json",
        ServerSideEncryption="aws:kms",
    )

    # FIX #7: Mark completed LAST (after all writes succeed)
    mark_completed(request_id)


# =============================================================================
# FIX #1 + #6: Correct Lambda handler with ReportBatchItemFailures
# Before: Always returns {"statusCode": 200} — SQS deletes ALL messages
# After:  Returns {"batchItemFailures": [...]} — SQS retries only failures
# =============================================================================

def lambda_handler(event: dict, context: Any) -> dict:
    """
    SQS batch processor with partial failure reporting.

    Return contract:
        {"batchItemFailures": [{"itemIdentifier": "<messageId>"}, ...]}

    - Messages NOT in batchItemFailures are considered successfully processed.
    - Messages IN batchItemFailures are returned to the queue for retry.
    - After maxReceiveCount retries, messages route to the Dead Letter Queue.
    """
    batch_item_failures: list[dict] = []
    records = event.get("Records", [])

    logger.info("Batch received", extra={
        "total": len(records),
        "message_id": getattr(context, "aws_request_id", "local"),
    })

    for record in records:
        message_id = record.get("messageId", "unknown")

        try:
            # Parse message body
            try:
                trade = json.loads(record["body"])
            except (json.JSONDecodeError, KeyError) as e:
                raise ValidationError(f"Malformed message body: {e}")

            # FIX #4: PII-safe logging — ONLY safe identifiers
            # Before: print(f"Processing customer trade: {trade}") ← leaked everything!
            logger.info("Processing trade", extra={
                "request_id": trade.get("request_id", "unknown"),
                "symbol": trade.get("symbol", "unknown"),
                "message_id": message_id,
            })

            # FIX #5: Validate before any processing
            validate_trade(trade)

            # FIX #2: Atomic idempotency lock
            request_id = trade["request_id"]
            if not acquire_idempotency_lock(request_id):
                continue  # Already processed — not a failure, just skip

            # Process the trade (all writes happen here)
            process_trade(trade)

            logger.info("Trade processed successfully", extra={
                "request_id": request_id,
                "message_id": message_id,
            })

        except ValidationError as e:
            # Non-retryable — report as failure so it counts toward maxReceiveCount
            # After maxReceiveCount, SQS routes to DLQ automatically
            logger.warning("Validation failed", extra={
                "message_id": message_id,
                "error_type": "ValidationError",
                "error": str(e),
            })
            batch_item_failures.append({"itemIdentifier": message_id})

        except Exception as e:
            # Transient failure — report for SQS retry
            # FIX #4: Don't log the record body (contains PII)
            logger.error("Processing failed, will retry", extra={
                "message_id": message_id,
                "error_type": type(e).__name__,
                "error": str(e),
            }, exc_info=True)
            batch_item_failures.append({"itemIdentifier": message_id})

    logger.info("Batch complete", extra={
        "total": len(records),
        "failed": len(batch_item_failures),
    })

    # FIX #1 + #6: Correct SQS return format
    # Before: {"statusCode": 200, "body": "..."} ← API Gateway format, SQS ignores it!
    # After:  {"batchItemFailures": [...]} ← SQS retries only these messages
    return {"batchItemFailures": batch_item_failures}
