# Interview Q&A Practice Session
## Terraform IaC + Python — Vertical Broker Trade Processor

---

# PART 1: TERRAFORM QUESTIONS & ANSWERS

---

## Q1: What's wrong with the junior's SQS queue configuration?

**Junior's code:**
```hcl
resource "aws_sqs_queue" "trade_queue" {
  name                       = "trade-processing-queue"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 86400
}
```

**Senior Answer:**

"I see four problems:

1. **No Dead Letter Queue** — If a message fails repeatedly, it stays in the queue
   forever, being retried infinitely. We need a DLQ with `redrive_policy` and
   `maxReceiveCount = 3` so poison messages are quarantined after 3 attempts.

2. **Visibility timeout too low** — The Lambda timeout is 60 seconds, but visibility
   timeout is only 30 seconds. If Lambda takes longer than 30s, SQS makes the message
   visible again, causing a DUPLICATE execution while the first is still running.
   Rule: `visibility_timeout >= lambda_timeout × 6`.

3. **No encryption** — Trade messages contain financial data. SQS must have
   `sqs_managed_sse_enabled = true` for encryption at rest.

4. **Hardcoded name** — No environment prefix. Dev, staging, and prod would collide
   or you'd need separate Terraform workspaces without knowing which queue is which.

I would fix it as:
```hcl
resource "aws_sqs_queue" "trade_queue" {
  name                       = "${local.name_prefix}-trade-queue"
  visibility_timeout_seconds = var.lambda_timeout * 6
  message_retention_seconds  = 345600
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.trade_dlq.arn
    maxReceiveCount     = 3
  })
}
```"

---

## Q2: The junior developer uses `dynamodb:*` and `Resource = "*"` in IAM. Why is this dangerous?

**Junior's code:**
```hcl
{
  Effect   = "Allow"
  Action   = ["dynamodb:*"]
  Resource = "*"
}
```

**Senior Answer:**

"This violates the principle of least privilege in multiple ways:

1. **`dynamodb:*` includes destructive actions** — `DeleteTable`, `UpdateTable`,
   `CreateBackup`, `RestoreTableFromBackup`. If the Lambda is compromised (dependency
   injection, SSRF), the attacker can delete ALL DynamoDB tables in the account.

2. **`Resource = "*"` means ALL tables** — Not just our orders table, but every
   DynamoDB table in the account. The blast radius of a security incident expands
   from one table to the entire database infrastructure.

3. **Audit failure** — When Security runs `IAM Access Analyzer` or `Prowler`, this
   will flag as a critical finding and block SOC 2 / PCI compliance certification.

The fix is to specify exact actions and exact resource ARNs:
```hcl
{
  Effect = "Allow"
  Action = [
    "dynamodb:PutItem",
    "dynamodb:GetItem",
    "dynamodb:UpdateItem"
  ]
  Resource = [
    aws_dynamodb_table.orders.arn,
    aws_dynamodb_table.idempotency.arn
  ]
}
```

This Lambda only needs to put, get, and update items on two specific tables.
Nothing more."

---

## Q3: Why does the event source mapping need `function_response_types`?

**Junior's code:**
```hcl
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.trade_queue.arn
  function_name    = aws_lambda_function.trade_processor.arn
  batch_size       = 100
  enabled          = true
}
```

**Senior Answer:**

"Without `function_response_types = ["ReportBatchItemFailures"]`, SQS uses the
**all-or-nothing** model. If the Lambda returns successfully (doesn't throw), SQS
deletes ALL messages in the batch — even if some failed internally.

This means:
- Our Python code returns `{"batchItemFailures": [...]}`
- But SQS IGNORES that response because we haven't opted into partial batch reporting
- All 100 messages are deleted, including the failures
- We've built the Python code correctly but the infrastructure silently discards it

The Terraform and Python must be aligned:

```hcl
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn        = aws_sqs_queue.trade_queue.arn
  function_name           = aws_lambda_function.trade_processor.arn
  batch_size              = 10    # Smaller batches = less blast radius
  function_response_types = ["ReportBatchItemFailures"]  # CRITICAL

  maximum_batching_window_in_seconds = 5
}
```

Also, `batch_size = 100` is too aggressive. If one message takes 5 seconds to process,
100 messages = 500 seconds, far exceeding any reasonable Lambda timeout. I'd use 10
with a 5-second batching window."

---

## Q4: What's missing from the junior's S3 bucket configuration?

**Junior's code:**
```hcl
resource "aws_s3_bucket" "reports" {
  bucket = "verticalbroker-production-trade-reports"
}
```

**Senior Answer:**

"This is a completely unprotected S3 bucket storing financial trade reports. Missing:

1. **No public access block** — Without `aws_s3_bucket_public_access_block`, someone
   could accidentally add a public bucket policy. Financial reports become public.

2. **No encryption** — Trade data stored in plaintext. Violates PCI-DSS and SOC 2
   data-at-rest encryption requirements.

3. **No versioning** — If a file is overwritten or deleted, it's gone forever. No
   ability to recover from corruption or accidental deletion.

4. **No lifecycle rules** — Financial records have regulatory retention requirements
   (often 7 years). Without lifecycle rules, data either accumulates at full S3 cost
   forever, or someone manually deletes it violating retention requirements.

5. **Hardcoded bucket name** — No environment isolation.

The fix requires 4 separate resources in modern Terraform (post-v4 provider):
```hcl
resource "aws_s3_bucket" "reports" { ... }
resource "aws_s3_bucket_versioning" "reports" { ... }
resource "aws_s3_bucket_server_side_encryption_configuration" "reports" { ... }
resource "aws_s3_bucket_public_access_block" "reports" { ... }
resource "aws_s3_bucket_lifecycle_configuration" "reports" { ... }
```"

---

## Q5: Why should the DynamoDB orders table use PAY_PER_REQUEST instead of PROVISIONED?

**Junior's code:**
```hcl
resource "aws_dynamodb_table" "orders" {
  billing_mode   = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5
}
```

**Senior Answer:**

"For a trade processing system:

1. **Traffic is bursty** — Trade volume spikes during market open (9:30 AM), market
   close (4:00 PM), and during volatility events. Fixed capacity of 5 WCU means we
   can only handle 5 writes/second. During a spike, DynamoDB throws
   `ProvisionedThroughputExceededException` and trades fail.

2. **Capacity 5 is absurdly low** — Even a small broker processes thousands of trades
   per minute during peaks. 5 WCU = 5 orders/second maximum.

3. **Auto-scaling has lag** — Even with auto-scaling configured (which it isn't here),
   DynamoDB takes 5-15 minutes to scale up. By then, the trading spike is over and
   you've lost thousands of messages.

4. **PAY_PER_REQUEST** handles this automatically — it scales instantly to any traffic
   level (up to account limits), and you only pay per request. For unpredictable,
   bursty financial workloads, it's the correct choice.

5. **Missing Point-in-Time Recovery** — This is a financial data table. Without PITR,
   if data is corrupted, we have no way to recover. This is a regulatory requirement.

```hcl
resource "aws_dynamodb_table" "orders" {
  billing_mode = "PAY_PER_REQUEST"

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  deletion_protection_enabled = true
}
```"

---

## Q6: The junior has no CloudWatch alarms. What monitoring would you add?

**Senior Answer:**

"For a financial trade processor, I need three critical alarms minimum:

**1. Lambda Error Rate Alarm:**
```hcl
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  metric_name = "Errors"
  namespace   = "AWS/Lambda"
  threshold   = 5
  period      = 300
}
```
Fires if more than 5 Lambda errors in 5 minutes. Indicates code failures or
infrastructure issues.

**2. DLQ Depth Alarm (MOST CRITICAL):**
```hcl
resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  metric_name = "ApproximateNumberOfMessagesVisible"
  namespace   = "AWS/SQS"
  threshold   = 0
  # QueueName  = trade_dlq
}
```
Any message in the DLQ means a customer trade FAILED after 3 retries. This is a
revenue-impacting incident. Threshold = 0 because even ONE failed trade needs
investigation.

**3. Queue Depth Alarm:**
```hcl
resource "aws_cloudwatch_metric_alarm" "queue_depth" {
  metric_name = "ApproximateNumberOfMessagesVisible"
  namespace   = "AWS/SQS"
  threshold   = 1000
  # QueueName  = trade_queue
}
```
If the backlog exceeds 1000 messages, processing isn't keeping up. Could indicate
Lambda throttling, DynamoDB issues, or a traffic spike needing attention.

Without these alarms, the team won't know trades are failing until customers complain."

---

## Q7: Why is `python3.9` a problem in the Lambda configuration?

**Senior Answer:**

"Python 3.9 reached end-of-life in October 2025. Running it in production means:

1. **No security patches** — Any CVE discovered in Python 3.9 will not be patched.
   For a financial system, this is an unacceptable compliance risk.

2. **AWS deprecation** — AWS will stop supporting Python 3.9 runtime, meaning
   no Lambda deployments or updates using this runtime.

3. **Missing features** — We're using `datetime.now(timezone.utc)` patterns,
   `match` statements, and typing improvements from 3.10+. Python 3.12 includes
   significant performance improvements (10-20% faster) which directly reduces
   Lambda execution cost.

4. **No X-Ray tracing configured** — The `tracing_config` block is missing entirely.
   Without X-Ray, we can't trace requests across SQS → Lambda → DynamoDB → S3
   to diagnose latency issues.

Fix: `runtime = "python3.12"` with `tracing_config { mode = "Active" }`"

---

## Q8: What Terraform features are completely missing from the junior's code?

**Senior Answer:**

"Major omissions:

1. **No `terraform` block** — No version constraints, no backend config. State is
   stored locally (lost if laptop dies), no state locking (team can corrupt state).

2. **No variables** — Everything is hardcoded. Can't deploy to different environments
   without editing the code.

3. **No outputs** — Other teams/stacks can't reference our resources (queue URL,
   bucket name) without hardcoding them.

4. **No tags** — Can't track costs, ownership, or compliance. `aws:CostAllocation`
   tags are required for financial teams to attribute infrastructure costs.

5. **No remote backend** — State should be in S3 with DynamoDB locking for team
   collaboration.

6. **No provider version pinning** — `required_providers` block missing. A provider
   update could break the deployment without warning.

7. **No validation** — No `validation` blocks on variables to catch bad input
   before `apply`."

---

---

# PART 2: PYTHON QUESTIONS & ANSWERS

---

## Q9: Explain the TOCTOU race condition in detail. How many trades could be duplicated?

**Senior Answer:**

"TOCTOU = Time-Of-Check-Time-Of-Use.

**The race window:**
```
Timeline:
  T=0ms: Lambda-A calls get_item('req-123') → returns None (not found)
  T=1ms: Lambda-B calls get_item('req-123') → returns None (ALSO not found!)
  T=2ms: Lambda-A passes the if-check, continues processing
  T=2ms: Lambda-B passes the if-check, continues processing
  T=5ms: Lambda-A writes order to DynamoDB (customer charged)
  T=6ms: Lambda-B writes order to DynamoDB (customer charged AGAIN)
  T=8ms: Lambda-A writes idempotency record
  T=9ms: Lambda-B overwrites idempotency record
```

**How many trades could be duplicated?**

With SQS + Lambda, this happens during:
- **Retry storms** — SQS delivers the same message to multiple Lambda invocations
- **At-least-once delivery** — SQS's guaranteed delivery model means duplicates
- **Lambda scaling** — 100 concurrent Lambdas processing the same batch

In a worst case: EVERY trade could be duplicated if there's a burst of retries.
For a broker processing 10,000 trades/hour at an average of $500, that's
$5,000,000/hour in duplicate charges.

**The fix — atomic conditional write:**
```python
idempotency_table.put_item(
    Item={'request_id': request_id, 'status': 'IN_PROGRESS'},
    ConditionExpression='attribute_not_exists(request_id)',
)
```

This is a single atomic DynamoDB operation. If two Lambdas race:
- T=0ms: Lambda-A's put_item succeeds (condition met)
- T=1ms: Lambda-B's put_item FAILS with ConditionalCheckFailedException
- Result: Only ONE Lambda processes the trade. Zero duplicates."

---

## Q10: Why is `round(quantity * price, 2)` wrong for financial calculations?

**Senior Answer:**

"IEEE 754 floating-point cannot represent most decimal fractions exactly.

**Demonstration:**
```python
>>> 0.1 + 0.2
0.30000000000000004

>>> 0.1 * 3
0.30000000000000004

>>> 1.1 + 2.2
3.3000000000000003

>>> round(0.1 * 3, 2)  # Seems to work...
0.3

>>> round(2.675, 2)    # But this FAILS!
2.67  # Expected 2.68! Python rounds DOWN due to representation
```

The problem is that `2.675` is stored internally as `2.6749999999999998...` so
`round()` rounds it down to `2.67` instead of up to `2.68`.

**Financial impact:**
- Trade: Buy 267 shares at $2.675 each
- Expected total: $714.23 (rounded from $714.225 → banker's rounds to .22, not .23)
- Float calculation: `267 * 2.675 = 714.2249999999999` → `round(_, 2) = 714.22`
- Depending on the rounding direction of the error, customer pays more or less

Over millions of trades, these errors don't cancel out — they can systematically
bias in one direction.

**The fix:**
```python
from decimal import Decimal, ROUND_HALF_EVEN

price = Decimal('2.675')      # Stored EXACTLY as 2.675
quantity = Decimal('267')
total = (quantity * price).quantize(Decimal('0.01'), rounding=ROUND_HALF_EVEN)
# Result: Decimal('714.22') — exact, deterministic, correct
```

`ROUND_HALF_EVEN` (banker's rounding) rounds 0.5 to the nearest EVEN number,
eliminating systematic bias over large datasets."

---

## Q11: Walk through what happens when the S3 write fails but DynamoDB succeeds.

**Junior's code flow:**
```python
orders_table.put_item(Item=order)        # ✓ Succeeds
s3.put_object(Bucket=..., Body=...)      # ✗ FAILS (network timeout)
idempotency_table.put_item(Item={...})   # Never reached
```

**Senior Answer:**

"Here's the failure cascade:

**First execution:**
1. Order written to DynamoDB ✓ (customer will be charged)
2. S3 write fails (timeout, throttle, network error) ✗
3. Exception raised → caught by except block → printed
4. Idempotency record NEVER written
5. Lambda returns 200 → SQS deletes message (WRONG!)

**The state is now:**
- DynamoDB orders table: order EXISTS
- S3: report MISSING
- Idempotency table: record MISSING

**If we had proper retry (batchItemFailures):**
1. Message returned to SQS for retry
2. Second Lambda picks it up
3. Idempotency check: `get_item('req-123')` → None (no record!)
4. Passes check → writes order AGAIN → **DUPLICATE**

**The compounding failures:**
- The junior's code has NO conditional write on the orders table
- So `put_item` OVERWRITES the existing order (possibly with different timestamp)
- Customer now has duplicate financial record
- Reconciliation breaks

**Senior's fix — correct ordering:**
```python
# Step 1: Acquire lock FIRST (atomic conditional)
acquire_idempotency_lock(request_id)  # Fails if already exists

# Step 2: Write order with condition (no overwrite)
orders_table.put_item(
    Item=order,
    ConditionExpression='attribute_not_exists(order_id)',
)

# Step 3: S3 write (naturally idempotent — same key = safe overwrite)
s3.put_object(Bucket=..., Key=f'{request_id}.json', Body=...)

# Step 4: Mark completed LAST
mark_completed(request_id)
```

If S3 fails now:
- Lock is held (IN_PROGRESS)
- On retry, lock exists → we check if it's stale
- If stale (>5 min), reclaim and retry safely
- If not stale, skip (another Lambda is handling it)
- Order table has conditional write, so no duplicate regardless"

---

## Q12: Why is `print(f"Processing customer trade: {trade}")` a security issue?

**Senior Answer:**

"The `trade` dict contains:
```python
{
    'request_id': 'req-abc-123',
    'customer_id': 'cust-john-doe-456',  # PII
    'symbol': 'AAPL',
    'quantity': 100,
    'price': 150.00,
    'account_number': '****4567',        # Potentially present
    'email': 'john@example.com',         # Potentially present
}
```

**Where this data goes:**
1. CloudWatch Logs (retained for months/years)
2. CloudWatch Log Insights (queryable by entire team)
3. Log forwarding (Datadog, Splunk, ELK — often on separate security boundary)
4. CloudTrail (if API logging enabled)

**Compliance violations:**
- **PCI-DSS**: Cardholder data must not be stored in logs
- **SOC 2**: Access to PII must be controlled and audited
- **GDPR Art. 5(1)(c)**: Data minimization — don't process more data than necessary
- **CCPA**: Customer has right to know where their data is stored

**Attack scenario:**
An attacker gains read access to CloudWatch Logs (common — many IAM policies grant
`logs:*`). They now have:
- Customer IDs (can correlate with other systems)
- Trade patterns (insider trading intelligence)
- Account numbers (financial fraud)
- Full transaction history (identity theft)

**The fix — log ONLY non-PII identifiers:**
```python
logger.info('Processing trade', extra={
    'request_id': trade.get('request_id'),  # Internal ID — safe
    'symbol': trade.get('symbol'),          # Public market data — safe
    'message_id': message_id,              # SQS internal ID — safe
})
```

Never log: customer_id, email, name, account_number, full payload"

---

## Q13: What's wrong with returning `{"statusCode": 200}` from an SQS-triggered Lambda?

**Senior Answer:**

"The return value format depends on the TRIGGER TYPE:

| Trigger | Expected Return |
|---------|----------------|
| API Gateway | `{'statusCode': 200, 'body': '...'}` |
| SQS (batch) | `{'batchItemFailures': [...]}` |
| SQS (no batch reporting) | Nothing (throw to retry all) |
| SNS | Nothing |
| EventBridge | Nothing |

The junior confused the API Gateway contract with the SQS contract.

**What actually happens:**
1. SQS invokes Lambda with batch of 10 messages
2. 3 messages fail internally
3. Lambda returns `{'statusCode': 200}` 
4. SQS sees: 'Lambda returned successfully (no exception thrown)'
5. SQS concludes: 'ALL 10 messages processed successfully'
6. SQS DELETES all 10 messages from queue
7. 3 failed trades are permanently lost

**The correct contract with `ReportBatchItemFailures`:**
```python
return {
    'batchItemFailures': [
        {'itemIdentifier': 'msg-id-7'},
        {'itemIdentifier': 'msg-id-9'},
        {'itemIdentifier': 'msg-id-10'},
    ]
}
```

SQS then:
- Deletes messages 1-6, 8 (succeeded)
- Returns messages 7, 9, 10 to the queue (will retry)
- After `maxReceiveCount` retries, routes to DLQ

**CRITICAL**: Both the Python code AND the Terraform must agree:
- Python returns `batchItemFailures`
- Terraform sets `function_response_types = ['ReportBatchItemFailures']`
- If EITHER is missing, partial batch reporting doesn't work"

---

## Q14: How would you handle the 'stale lock' problem in the idempotency pattern?

**Senior Answer:**

"The problem: Lambda acquires idempotency lock (status=IN_PROGRESS), then crashes
before completing. The lock blocks all future retries forever.

**Scenario:**
1. Lambda-A acquires lock: `{request_id: 'x', status: 'IN_PROGRESS', locked_at: '10:00:00'}`
2. Lambda-A crashes (OOM, timeout, runtime error)
3. SQS retries → Lambda-B tries to acquire lock
4. Lock exists (IN_PROGRESS) → Lambda-B skips
5. Trade is NEVER processed

**My solution — staleness detection with conditional reclaim:**

```python
LOCK_STALENESS_SECONDS = 300  # 5 minutes (5× Lambda timeout)

def acquire_idempotency_lock(request_id):
    try:
        # Try atomic acquire
        idempotency_table.put_item(
            Item={'request_id': request_id, 'status': 'IN_PROGRESS',
                  'locked_at': now.isoformat(), 'expires_at': int(now_epoch) + TTL},
            ConditionExpression='attribute_not_exists(request_id)',
        )
        return True
    except ConditionalCheckFailedException:
        # Lock exists — check if stale
        existing = idempotency_table.get_item(Key={'request_id': request_id})['Item']
        
        if existing['status'] == 'COMPLETED':
            return False  # Already done — skip
        
        # Check age of IN_PROGRESS lock
        locked_at = datetime.fromisoformat(existing['locked_at'])
        age = (now - locked_at).total_seconds()
        
        if age > LOCK_STALENESS_SECONDS:
            # Reclaim with conditional write (prevent race on reclaim itself)
            idempotency_table.put_item(
                Item={'request_id': request_id, 'status': 'IN_PROGRESS',
                      'locked_at': now.isoformat(), ...},
                ConditionExpression='locked_at = :old_lock',
                ExpressionAttributeValues={':old_lock': existing['locked_at']},
            )
            return True  # Lock reclaimed
        
        return False  # Lock is fresh — another Lambda is working on it
```

**Why `ConditionExpression='locked_at = :old_lock'` on the reclaim:**
If two Lambdas both detect a stale lock simultaneously, only one can reclaim it.
The conditional ensures the reclaim itself is atomic — the second Lambda gets
`ConditionalCheckFailedException` and backs off.

**Why 5 minutes (5× Lambda timeout):**
Lambda max timeout = 60s. If the lock is 5 minutes old, there's no possible way
the original Lambda is still running. Safe to reclaim."

---

## Q15: Design a complete error handling strategy for this Lambda.

**Senior Answer:**

"I use a two-tier error classification:

**Tier 1: Non-Retryable (ValidationError)**
- Missing/invalid fields, malformed JSON, business rule violations
- These will NEVER succeed no matter how many times we retry
- Strategy: Report in `batchItemFailures`, let SQS count toward `maxReceiveCount`,
  route to DLQ after 3 attempts for human investigation

**Tier 2: Transient/Retryable (everything else)**
- DynamoDB throttling, S3 timeouts, network errors
- These may succeed on retry
- Strategy: Report in `batchItemFailures`, SQS retries with backoff

**Implementation:**
```python
for record in records:
    try:
        trade = json.loads(record['body'])     # Can raise JSONDecodeError
        validate_trade(trade)                   # Can raise ValidationError
        acquire_lock(trade['request_id'])       # Can raise ClientError
        process_trade(trade)                    # Can raise ClientError
    except ValidationError as e:
        # Tier 1: Log warning, report failure, let DLQ handle
        logger.warning('Validation failed', extra={...})
        batch_item_failures.append({'itemIdentifier': record['messageId']})
    except Exception as e:
        # Tier 2: Log error with stack trace, report for retry
        logger.error('Transient failure', extra={...}, exc_info=True)
        batch_item_failures.append({'itemIdentifier': record['messageId']})
```

**What I do NOT do:**
- ❌ Catch and swallow (junior's approach) — loses messages
- ❌ Raise unhandled exception — retries ENTIRE batch, including successes
- ❌ Return `statusCode: 200` — meaningless to SQS
- ❌ Log the full record/payload — PII exposure

**DLQ investigation process:**
Messages in DLQ get:
1. CloudWatch alarm fires (threshold=0)
2. On-call engineer investigates
3. Fix the root cause
4. Redrive messages from DLQ back to main queue
5. Messages reprocess successfully"

---

---

# PART 3: SCENARIO-BASED QUESTIONS

---

## Q16: It's Monday morning. The DLQ alarm has fired — 500 messages in the DLQ. Walk me through your investigation.

**Senior Answer:**

"Step-by-step investigation:

**1. Assess severity (first 2 minutes):**
```bash
# How many messages? Growing or stable?
aws sqs get-queue-attributes --queue-url $DLQ_URL \
  --attribute-names ApproximateNumberOfMessagesVisible

# Check main queue — is there a backlog too?
aws sqs get-queue-attributes --queue-url $MAIN_QUEUE_URL \
  --attribute-names ApproximateNumberOfMessagesVisible
```

**2. Sample DLQ messages (next 5 minutes):**
```bash
# Peek at a few messages (don't delete them)
aws sqs receive-message --queue-url $DLQ_URL --max-number-of-messages 5
```
Look at: Are they all the same customer? Same symbol? Same error pattern?

**3. Check Lambda logs (parallel):**
```bash
# CloudWatch Insights query
fields @timestamp, request_id, error_type, error
| filter level = 'ERROR'
| sort @timestamp desc
| limit 100
```

**4. Determine root cause:**
- All same customer → customer-specific data issue
- All same error → code bug or infrastructure issue
- Gradual accumulation → intermittent failures (throttling?)
- Sudden spike → deployment broke something

**5. Fix and redrive:**
```bash
# After fixing root cause, redrive DLQ messages
aws sqs start-message-move-task \
  --source-arn $DLQ_ARN \
  --destination-arn $MAIN_QUEUE_ARN
```

**6. Verify:**
- Watch main queue drain
- Confirm DLQ goes to 0
- Check orders table for processed trades
- No new errors in CloudWatch"

---

## Q17: A customer reports they were charged twice for the same trade. How do you investigate?

**Senior Answer:**

"**1. Get the request_id from the customer support ticket.**

**2. Query the orders table:**
```bash
aws dynamodb query --table-name orders \
  --key-condition-expression 'order_id = :id' \
  --expression-attribute-values '{":id": {"S": "req-xyz"}}'
```
Check: Is there actually a duplicate? Or is the customer confused?

**3. If duplicate exists, check the idempotency table:**
```bash
aws dynamodb get-item --table-name idempotency \
  --key '{"request_id": {"S": "req-xyz"}}'
```
- If status = COMPLETED → idempotency was set AFTER both writes (race condition)
- If missing → idempotency record expired (TTL too short) or was never written

**4. Check CloudWatch for concurrent executions:**
```
fields @timestamp, request_id, @requestId
| filter request_id = 'req-xyz'
| sort @timestamp asc
```
Look for two different `@requestId` (Lambda invocation IDs) processing the same trade
within milliseconds of each other → confirms TOCTOU race.

**5. Root cause determination:**
- If two concurrent executions → the get-then-put idempotency is broken
- Fix: atomic conditional write (our senior implementation)
- If same execution processed it twice → SQS retry caused duplicate delivery
- Fix: conditional write on orders table

**6. Remediation:**
- Refund the customer immediately
- Deploy the fix (atomic idempotency)
- Audit all orders for the past week to find other duplicates:
```sql
-- CloudWatch Insights
fields request_id, count(*) as cnt
| stats count(*) as cnt by request_id
| filter cnt > 1
```"

---

## Q18: You're asked to add a new feature: send an SNS notification after each successful trade. Where do you add it and what could go wrong?

**Senior Answer:**

"**Where to add it:**
After `mark_completed(request_id)` — the trade is fully processed and committed.

```python
def process_trade(trade):
    ...
    orders_table.put_item(Item=order, ConditionExpression=...)
    s3.put_object(Bucket=..., Key=..., Body=...)
    mark_completed(request_id)
    
    # NEW: Notification (best-effort, after commit)
    try:
        sns.publish(
            TopicArn=TRADE_NOTIFICATION_TOPIC,
            Message=json.dumps({
                'request_id': request_id,
                'symbol': symbol,
                'quantity': quantity,
                'status': 'PROCESSED',
            }),
            MessageAttributes={...}
        )
    except Exception as e:
        # Log but do NOT fail the trade
        logger.warning('SNS notification failed', extra={
            'request_id': request_id,
            'error': str(e),
        })
```

**What could go wrong:**

1. **If SNS is before `mark_completed`** and SNS fails → the trade is processed but
   idempotency isn't marked. On retry, we'd reprocess and send duplicate notifications.

2. **If SNS failure causes the trade to fail** → customers don't get their trades
   because a non-critical notification service is down. Never couple critical path
   to non-critical services.

3. **PII in notification** → Don't include customer_id or personal data in SNS.
   SNS topics may have multiple subscribers with different access levels.

4. **Idempotency of notifications** → The notification itself should be idempotent.
   Include `request_id` so downstream consumers can deduplicate.

**Terraform additions needed:**
```hcl
resource "aws_sns_topic" "trade_notifications" { ... }

# Add to Lambda IAM:
Action = ["sns:Publish"]
Resource = [aws_sns_topic.trade_notifications.arn]

# Add env var:
TRADE_NOTIFICATION_TOPIC = aws_sns_topic.trade_notifications.arn
```"

---

---

# QUICK-FIRE QUESTIONS (30-second answers)

---

**Q19: `os.environ.get()` vs `os.environ[]` — when to use which?**

"Use `os.environ[]` (bracket) for REQUIRED configuration that the Lambda cannot
function without. It fails fast at import time with a clear `KeyError`. Use
`os.environ.get()` only for OPTIONAL configuration with safe defaults (like LOG_LEVEL)."

---

**Q20: Why `ROUND_HALF_EVEN` instead of `ROUND_HALF_UP`?**

"ROUND_HALF_UP always rounds 0.5 upward, creating a systematic bias that accumulates
over millions of transactions. ROUND_HALF_EVEN (banker's rounding) rounds 0.5 to the
nearest even number (2.5→2, 3.5→4), distributing rounding errors equally in both
directions. This is the standard in financial systems and IEEE 754."

---

**Q21: What's the difference between SQS Standard and FIFO for this use case?**

"Standard Queue: at-least-once delivery, nearly unlimited throughput, messages may
arrive out of order. FIFO Queue: exactly-once processing, ordered, limited to 3000
messages/second. For trades: Standard + idempotency is better because we need high
throughput during market hours, and our application-level idempotency handles duplicates.
FIFO's throughput limit would become a bottleneck during volatility spikes."

---

**Q22: Why `billing_mode = "PAY_PER_REQUEST"` instead of provisioned with autoscaling?**

"Autoscaling reacts to sustained load over 5-15 minutes. Trading spikes happen in
seconds (market open, news events). By the time autoscaling reacts, you've already
throttled thousands of trades. PAY_PER_REQUEST scales instantly at the request level
with no warm-up. The cost premium (~20% more per request) is trivial compared to
lost trades."

---

**Q23: The Lambda times out at 60s. What happens to in-flight SQS messages?**

"If Lambda times out, the function is killed. SQS never receives a response (no
batchItemFailures returned). SQS waits for `visibility_timeout` to expire, then makes
ALL messages in that batch visible again for retry. This is why visibility_timeout must
be >= 6× Lambda timeout — if it's shorter, the message becomes visible while Lambda is
still processing, causing duplicate execution."

---

**Q24: Why separate IAM policies instead of one big policy document?**

"1. **Readability** — Each policy has a clear name ('dynamodb-access', 's3-reports')
2. **Blast radius** — Can revoke one permission without touching others
3. **IAM policy size limits** — AWS has a 10,240 character limit per managed policy
4. **Audit clarity** — Security team can review each grant independently
5. **Reusability** — Can attach 'dynamodb-access' to another role if needed"

---

**Q25: What happens if you forget `function_response_types = ["ReportBatchItemFailures"]` in Terraform but return `batchItemFailures` in Python?**

"SQS ignores the response body entirely. It treats any successful Lambda return (no
exception thrown) as 'all messages processed.' All messages are deleted from the queue —
including the ones you reported as failed. Your Python code is correct but the
infrastructure silently discards the failure information. The Python and Terraform
MUST be aligned."

---
