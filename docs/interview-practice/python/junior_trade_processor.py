"""
Trade Processor Lambda — Junior Developer Submission
=====================================================
This code contains multiple production-critical errors.
Submitted for peer review before production deployment.
"""

import json
import os
import time
from datetime import datetime

import boto3


# ERROR 1 (P1): Hardcoded production resource names as fallback defaults.
# If env vars are missing, dev/staging Lambda silently writes to PRODUCTION.
dynamodb = boto3.resource("dynamodb")  # ERROR 2 (P1): No retry/backoff configuration
s3 = boto3.client("s3")               # ERROR 2 continued: No retry config on S3 either

orders_table = dynamodb.Table(
    os.environ.get("ORDERS_TABLE", "verticalbroker-prod-orders")  # ERROR 1: prod fallback
)

idempotency_table = dynamodb.Table(
    os.environ.get(
        "IDEMPOTENCY_TABLE",
        "verticalbroker-prod-idempotency"  # ERROR 1: prod fallback
    )
)

REPORT_BUCKET = os.environ.get(
    "REPORT_BUCKET",
    "verticalbroker-production-trade-reports"  # ERROR 1: prod fallback
)


def lambda_handler(event, context):
    # ERROR 3 (P2): No type hints on handler signature
    for record in event.get("Records", []):
        try:
            trade = json.loads(record["body"])

            # ERROR 4 (P0 — SECURITY): Logs entire trade payload including PII
            # customer_id, potentially name, account info all go to CloudWatch
            print(f"Processing customer trade: {trade}")

            # ERROR 5 (P0): No input validation whatsoever
            # All these could be None, empty, or malicious values
            request_id = trade.get("request_id")    # Could be None!
            customer_id = trade.get("customer_id")  # Could be None!
            symbol = trade.get("symbol")            # Could be "'; DROP TABLE--"!
            quantity = int(trade.get("quantity", 0))  # Defaults to 0! Allows negative!
            price = float(trade.get("price", 0))     # ERROR 6 (P0): float for money!

            # ERROR 7 (P0 — RACE CONDITION): get-then-put is NOT atomic
            # Two concurrent Lambdas can both read "not found" and both proceed
            existing = idempotency_table.get_item(
                Key={"request_id": request_id}
            ).get("Item")

            if existing:
                print(f"Request already processed: {request_id}")
                continue

            # ERROR 6 (P0 — FINANCIAL): Floating-point arithmetic for money
            # float(0.1) * 3 = 0.30000000000000004, not 0.30
            total_amount = round(quantity * price, 2)

            order = {
                "order_id": request_id,
                "request_id": request_id,
                "customer_id": customer_id,
                "symbol": symbol,
                "quantity": quantity,
                "price": price,  # Stored as float — precision loss in DynamoDB
                "total_amount": total_amount,  # Stored as float — precision loss
                "status": "PROCESSED",
                # ERROR 8 (P1): datetime.utcnow() is deprecated (Python 3.12+)
                # and produces timezone-NAIVE string (no +00:00 or Z suffix)
                "processed_at": datetime.utcnow().isoformat()
            }

            # ERROR 9 (P1): No conditional write — allows overwriting existing orders
            orders_table.put_item(Item=order)

            # ERROR 10 (P1): Non-atomic multi-resource writes
            # If S3 fails here, order is written but idempotency is not.
            # On retry, idempotency check passes → DUPLICATE ORDER
            report_key = (
                f"customers/{customer_id}/"
                f"trades/{request_id}.json"
            )

            # No ContentType, no encryption
            s3.put_object(
                Bucket=REPORT_BUCKET,
                Key=report_key,
                Body=json.dumps(order)
            )

            # ERROR 11 (P2): time.time() returns float, DynamoDB TTL needs int
            # Float may not trigger TTL sweeper → unbounded table growth
            idempotency_table.put_item(
                Item={
                    "request_id": request_id,
                    "status": "COMPLETED",
                    "expires_at": time.time() + 86400  # Float, not int!
                }
            )

            # ERROR 4 continued: Logs customer_id (PII)
            print(
                f"Successfully processed order "
                f"{request_id} for customer {customer_id}"
            )

        # ERROR 12 (P0 — MESSAGE LOSS): Catches ALL exceptions silently
        # Failed messages are never retried — they vanish forever
        except Exception as error:
            # ERROR 4 continued: Logs entire record (contains message body with PII)
            # ERROR 13 (P2): No structured logging, no correlation ID
            print(
                f"Trade processing failed: "
                f"{record}; error={error}"
            )

    # ERROR 14 (P0 — MESSAGE LOSS): Returns API Gateway format, not SQS format
    # SQS ignores statusCode entirely. Without batchItemFailures,
    # SQS assumes ALL messages succeeded and deletes them from the queue.
    # Failed messages are PERMANENTLY LOST with no retry, no DLQ routing.
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": "Batch processed successfully"
        })
    }
