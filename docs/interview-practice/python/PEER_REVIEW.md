# Peer Review: Trade Processor Lambda

**Reviewer:** Senior Engineer  
**Author:** Junior Developer  
**Status:** ❌ REQUEST CHANGES — Do NOT merge  
**Risk Level:** CRITICAL — Financial data loss, duplicate charges, compliance breach

---

## Executive Summary

This Lambda processes real customer trades (money movements). The current implementation
has **14 identified issues**, including 6 at P0 severity that would cause:

- Permanent loss of customer trade messages (silent failures)
- Duplicate financial charges (race condition)
- Incorrect monetary calculations (floating-point)
- PII exposure in logs (compliance violation)

**Verdict:** Code must be substantially rewritten before production deployment.

---

## Detailed Findings

### 🔴 P0 — CRITICAL: Message Loss, Duplicate Money, Security Breach

---

#### Finding #1: Silent Message Loss (Lines 97–107)

**What I observed:**
```python
except Exception as error:
    print(f"Trade processing failed: {record}; error={error}")

return {"statusCode": 200, "body": json.dumps({"message": "Batch processed successfully"})}
```

**Production impact:**  
Every failed trade message is permanently deleted from SQS. The function catches all
exceptions, prints them, and returns a 200 response. SQS interprets any return without
`batchItemFailures` as "all messages processed successfully" and removes them from the
queue. Failed customer trades vanish forever — no retry, no DLQ routing, no alert.
At scale, this could mean hundreds of lost trades per hour during an outage.

**What should have been done:**
```python
batch_item_failures = []
for record in records:
    try:
        process(record)
    except Exception:
        batch_item_failures.append({"itemIdentifier": record["messageId"]})

return {"batchItemFailures": batch_item_failures}
```

**How to test:**
- Unit test: inject DynamoDB error mid-batch → assert failed messageId in response
- Integration test: process batch of 5 where 2 fail → assert exactly 2 in batchItemFailures
- Verify SQS event source mapping has `FunctionResponseTypes: ["ReportBatchItemFailures"]`

---

#### Finding #2: Idempotency Race Condition (Lines 56–63)

**What I observed:**
```python
existing = idempotency_table.get_item(Key={"request_id": request_id}).get("Item")
if existing:
    continue
# ... later ...
idempotency_table.put_item(Item={"request_id": request_id, "status": "COMPLETED", ...})
```

**Production impact:**  
Classic TOCTOU (Time-Of-Check-Time-Of-Use) race. During SQS retry storms or Lambda
scaling events, two invocations process the same message concurrently:
1. Lambda-A reads idempotency table → "not found"
2. Lambda-B reads idempotency table → "not found" (concurrent)
3. Lambda-A writes order → customer charged
4. Lambda-B writes order → customer charged AGAIN

This is a **duplicate financial action** — the customer is charged twice.

**What should have been done:**
```python
# Atomic check-and-lock in a SINGLE operation
try:
    idempotency_table.put_item(
        Item={"request_id": request_id, "status": "IN_PROGRESS", ...},
        ConditionExpression="attribute_not_exists(request_id)",
    )
except ConditionalCheckFailedException:
    # Already exists — skip safely
    continue
```

**How to test:**
- Concurrent test: 10 threads process same request_id → assert exactly 1 order created
- Mock test: simulate `ConditionalCheckFailedException` → assert graceful skip

---

#### Finding #3: Floating-Point Money (Lines 50, 67)

**What I observed:**
```python
price = float(trade.get("price", 0))       # Line 50
total_amount = round(quantity * price, 2)   # Line 67
```

**Production impact:**  
IEEE 754 floating-point cannot represent all decimal fractions:
- `float(0.1) * 3` = `0.30000000000000004` (not `0.30`)
- `float(0.1) + float(0.2)` = `0.30000000000000004`

Over thousands of daily trades, rounding errors accumulate. A single basis-point
error across 10,000 trades at $1,000 each = $1,000 discrepancy. Reconciliation
failures, regulatory reporting errors, and customer disputes follow.

**What should have been done:**
```python
from decimal import Decimal, ROUND_HALF_EVEN

price = Decimal(str(trade["price"]))
quantity = Decimal(str(trade["quantity"]))
total_amount = (quantity * price).quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)
```

**How to test:**
- Assert `quantity=3, price="0.1"` → total = `Decimal("0.30")` exactly
- Assert `quantity=1, price="0.015"` → rounds to `Decimal("0.02")` (banker's rounding)
- Fuzz test with random prices → verify all results have exactly 2 decimal places

---

#### Finding #4: PII Logged in Plaintext (Lines 46, 95, 101)

**What I observed:**
```python
print(f"Processing customer trade: {trade}")                    # Line 46: FULL PAYLOAD
print(f"Successfully processed order {request_id} for customer {customer_id}")  # Line 95
print(f"Trade processing failed: {record}; error={error}")     # Line 101: FULL RECORD
```

**Production impact:**  
CloudWatch Logs now contain:
- Customer IDs (PII)
- Full trade payloads (potentially name, account, address)
- Raw SQS records (message bodies with all customer data)

This violates PCI-DSS (credit card environment), SOC 2 (access controls), and GDPR
(data minimization). CloudWatch logs are often:
- Accessible to broad engineering teams
- Retained for months/years
- Shipped to third-party log aggregators
- Not encrypted at field level

**What should have been done:**
```python
logger.info("Processing trade", extra={
    "request_id": trade.get("request_id"),  # Safe identifier
    "symbol": trade.get("symbol"),          # Non-PII business data
    "message_id": message_id,              # Correlation ID
})
# NEVER log: customer_id, full trade payload, raw record body
```

**How to test:**
- Capture log output in tests
- Assert `customer_id` value NEVER appears in any log line
- Assert full trade dict is never serialized to logs

---

#### Finding #5: No Input Validation (Lines 47–50)

**What I observed:**
```python
request_id = trade.get("request_id")         # None if missing
customer_id = trade.get("customer_id")       # None if missing
symbol = trade.get("symbol")                 # Any string, no format check
quantity = int(trade.get("quantity", 0))      # Defaults to 0, allows negative
price = float(trade.get("price", 0))         # Defaults to 0.0, allows negative
```

**Production impact:**
- `request_id = None` → DynamoDB key is `None` → corrupted table
- `quantity = 0` → zero-dollar order written to database
- `quantity = -5` → negative trade amount (effective refund injection)
- `symbol = "../../../etc/passwd"` → path traversal in S3 key
- `price = 0` → division errors downstream, meaningless financial record

A malicious or malformed message creates garbage financial records that corrupt
reporting, reconciliation, and audit trails.

**What should have been done:**
```python
def validate_trade(trade: dict) -> None:
    if not trade.get("request_id"):
        raise ValidationError("Missing request_id")
    if not trade.get("customer_id"):
        raise ValidationError("Missing customer_id")
    if not re.match(r"^[A-Z]{1,5}$", trade.get("symbol", "")):
        raise ValidationError("Invalid symbol")
    if int(trade.get("quantity", 0)) <= 0:
        raise ValidationError("Quantity must be positive")
    if Decimal(str(trade.get("price", 0))) <= 0:
        raise ValidationError("Price must be positive")
```

**How to test:**
- Parameterized test: None/empty/negative/overflow for each field
- Assert each produces a specific ValidationError
- Assert NO writes occur when validation fails

---

#### Finding #6: Return Format Incompatible with SQS (Lines 103–107)

**What I observed:**
```python
return {
    "statusCode": 200,
    "body": json.dumps({"message": "Batch processed successfully"})
}
```

**Production impact:**  
This is an API Gateway response format. SQS Lambda integration completely ignores it.
The correct contract for `ReportBatchItemFailures` is:
```python
return {"batchItemFailures": [{"itemIdentifier": "messageId123"}]}
```

Without this, SQS has no mechanism to know which messages failed. Combined with the
catch-all exception handler, this means **100% of failures result in message loss**.

**What should have been done:**
Return `{"batchItemFailures": batch_item_failures}` and ensure the SQS event source
mapping includes `FunctionResponseTypes: ["ReportBatchItemFailures"]`.

---

### 🟠 P1 — Reliability / Operational Risk

---

#### Finding #7: Non-Atomic Multi-Resource Writes (Lines 69–93)

**What I observed:**
```python
orders_table.put_item(Item=order)           # Step 1: Write order
s3.put_object(Bucket=..., Key=..., Body=...)  # Step 2: Write S3 report
idempotency_table.put_item(Item={...})      # Step 3: Write idempotency
```

**Production impact:**  
If S3 fails (network timeout, throttling) after the DynamoDB order write:
- Order exists in database ✓
- S3 report missing ✗
- Idempotency record missing ✗

On retry: idempotency check passes (no record), Lambda writes a DUPLICATE order.
The system is in an inconsistent state that cannot self-heal.

**What should have been done:**  
Write idempotency lock FIRST (as a mutex), then order, then report. Use conditional
writes on the order table. Mark idempotency COMPLETED last. S3 is naturally idempotent
(same key overwrites safely).

---

#### Finding #8: No Retry/Backoff Configuration (Lines 14–15)

**What I observed:**
```python
dynamodb = boto3.resource("dynamodb")
s3 = boto3.client("s3")
```

**Production impact:**  
During traffic spikes, DynamoDB throws `ProvisionedThroughputExceededException`.
Default boto3 retry is minimal (5 attempts, legacy mode). Without adaptive retry with
jitter, the Lambda fails fast during recoverable throttling events, causing unnecessary
message failures during peak trading hours.

**What should have been done:**
```python
config = Config(retries={"max_attempts": 3, "mode": "adaptive"})
dynamodb = boto3.resource("dynamodb", config=config)
```

---

#### Finding #9: Deprecated `datetime.utcnow()` (Line 76)

**What I observed:**
```python
"processed_at": datetime.utcnow().isoformat()
```

**Production impact:**  
- Produces `2024-01-15T10:30:00` — no timezone indicator
- Downstream systems cannot determine if this is UTC, EST, or PST
- Deprecated in Python 3.12 — generates runtime warnings in logs
- Off-by-hours errors in financial reporting

**What should have been done:**
```python
"processed_at": datetime.now(timezone.utc).isoformat()
# Produces: 2024-01-15T10:30:00+00:00
```

---

#### Finding #10: Hardcoded Production Defaults (Lines 17–30)

**What I observed:**
```python
os.environ.get("ORDERS_TABLE", "verticalbroker-prod-orders")
os.environ.get("IDEMPOTENCY_TABLE", "verticalbroker-prod-idempotency")
os.environ.get("REPORT_BUCKET", "verticalbroker-production-trade-reports")
```

**Production impact:**  
If a staging deployment has missing/misconfigured environment variables, it silently
connects to production DynamoDB tables and S3 buckets. A developer testing with fake
data could write test trades to production, corrupting real customer data. This also
leaks production resource names in source code.

**What should have been done:**
```python
ORDERS_TABLE_NAME = os.environ["ORDERS_TABLE"]  # KeyError if missing → fail fast
```

---

#### Finding #11: No Conditional Write on Orders Table (Line 69)

**What I observed:**
```python
orders_table.put_item(Item=order)  # Unconditional write
```

**Production impact:**  
If the same order is processed twice (due to the race condition or retry), the second
`put_item` silently overwrites the first. If the second execution has different data
(e.g., different timestamp), it corrupts the original record with no trace.

**What should have been done:**
```python
orders_table.put_item(
    Item=order,
    ConditionExpression="attribute_not_exists(order_id)",
)
```

---

### 🟡 P2 — Maintainability

---

#### Finding #12: Float TTL Value (Line 90)

**What I observed:**
```python
"expires_at": time.time() + 86400
```

**Production impact:**  
`time.time()` returns a float (e.g., `1705312200.123456`). DynamoDB TTL requires
Number type interpreted as epoch seconds. While DynamoDB may truncate the float,
the behavior is not guaranteed — idempotency records may never expire, causing
unbounded table growth and increasing costs.

**What should have been done:**
```python
"expires_at": int(time.time()) + 86400
```

---

#### Finding #13: No Structured Logging (Lines 46, 62, 95, 101)

**What I observed:**
```python
print(f"Processing customer trade: {trade}")
print(f"Request already processed: {request_id}")
print(f"Successfully processed order {request_id} for customer {customer_id}")
print(f"Trade processing failed: {record}; error={error}")
```

**Production impact:**
- Cannot query by `request_id` in CloudWatch Insights
- No log levels (INFO vs ERROR vs WARNING)
- No correlation IDs for distributed tracing
- No structured fields for alerting rules
- Debugging production issues requires manual log scanning

**What should have been done:**  
Use `logging` module with structured JSON formatter, include `request_id` and
`message_id` as extra fields, use appropriate log levels.

---

#### Finding #14: No S3 Encryption or Content Type (Lines 82–86)

**What I observed:**
```python
s3.put_object(
    Bucket=REPORT_BUCKET,
    Key=report_key,
    Body=json.dumps(order)
)
```

**Production impact:**
- No `ServerSideEncryption` — financial reports stored unencrypted (if bucket
  doesn't enforce encryption via policy)
- No `ContentType` — downstream consumers can't identify the file format
- Compliance risk for data-at-rest encryption requirements

**What should have been done:**
```python
s3.put_object(
    Bucket=REPORT_BUCKET,
    Key=report_key,
    Body=json.dumps(order, default=str),
    ContentType="application/json",
    ServerSideEncryption="aws:kms",
)
```

---

## Peer Review Verdict

| Category | Count | Issues |
|----------|-------|--------|
| P0 — Critical | 6 | Message loss, race condition, float money, PII, no validation, wrong return |
| P1 — Reliability | 5 | Non-atomic writes, no retry, deprecated datetime, prod defaults, no condition |
| P2 — Maintainability | 3 | Float TTL, no structured logging, no S3 encryption |
| **TOTAL** | **14** | |

### Required Before Approval:
1. ✅ Implement `ReportBatchItemFailures` return format
2. ✅ Replace get-then-put with atomic conditional write for idempotency
3. ✅ Use `Decimal` for all financial calculations
4. ✅ Remove all PII from log statements
5. ✅ Add input validation with field-level checks
6. ✅ Add conditional writes on orders table
7. ✅ Reorder writes: idempotency lock → order → S3 → mark completed
8. ✅ Configure adaptive retry on boto3 clients
9. ✅ Replace `datetime.utcnow()` with `datetime.now(timezone.utc)`
10. ✅ Remove production fallback defaults (fail fast)
11. ✅ Add structured logging with correlation IDs
12. ✅ Add S3 encryption and content type
13. ✅ Use `int()` for TTL values
14. ✅ Add comprehensive unit and failure tests

---

## Recommended Reading for the Junior Developer

- [AWS Lambda SQS Partial Batch Response](https://docs.aws.amazon.com/lambda/latest/dg/with-sqs.html#services-sqs-batchfailurereporting)
- [DynamoDB Conditional Writes](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Expressions.ConditionExpressions.html)
- [Python Decimal Module](https://docs.python.org/3/library/decimal.html)
- [OWASP Logging Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html)
