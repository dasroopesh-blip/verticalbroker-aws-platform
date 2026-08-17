# Terraform Peer Review — Junior Developer's Infrastructure Code

**Reviewer:** Senior Engineer  
**Author:** Junior Developer  
**Status:** ❌ REQUEST CHANGES — Critical security and reliability gaps  
**Risk Level:** CRITICAL — Wildcard IAM, no DLQ, no encryption, no monitoring

---

## Error Identification (Junior → Senior Fix)

---

### 🔴 P0 — Security / Data Loss

| # | Error | Junior's Code | Impact | Senior's Fix |
|---|-------|---------------|--------|--------------|
| 1 | Wildcard IAM (`dynamodb:*`, `s3:*`, `Resource = "*"`) | Lines 100–120 | Compromised Lambda can delete ALL tables, read ALL buckets | Specific actions on specific ARNs |
| 2 | No SQS DLQ | Line 14–18 | Poison messages retry infinitely, blocking queue | `redrive_policy` with `maxReceiveCount: 3` |
| 3 | Missing `function_response_types` | Lines 128–134 | `batchItemFailures` response silently ignored by SQS | `function_response_types = ["ReportBatchItemFailures"]` |
| 4 | No S3 public access block | Line 62–64 | Accidental public policy exposes financial reports | `aws_s3_bucket_public_access_block` with all 4 blocks |
| 5 | No encryption (DynamoDB, S3, SQS) | Throughout | Financial data at rest is unencrypted — PCI/SOC2 violation | `server_side_encryption`, `sqs_managed_sse_enabled`, KMS |

---

### 🟠 P1 — Reliability / Operational

| # | Error | Junior's Code | Impact | Senior's Fix |
|---|-------|---------------|--------|--------------|
| 6 | `visibility_timeout = 30` < Lambda timeout (60) | Line 16 | Messages become visible mid-processing → duplicates | `visibility_timeout = lambda_timeout × 6` |
| 7 | `billing_mode = "PROVISIONED"` with capacity 5 | Lines 26–28 | 5 writes/sec max → throttled during any real traffic | `PAY_PER_REQUEST` (instant scaling) |
| 8 | No Point-in-Time Recovery on orders | Line 24–34 | Data corruption/deletion is unrecoverable | `point_in_time_recovery { enabled = true }` |
| 9 | No DynamoDB TTL on idempotency table | Lines 38–50 | Table grows unbounded → cost + performance degradation | `ttl { attribute_name = "expires_at", enabled = true }` |
| 10 | `batch_size = 100` with no batching window | Line 131 | 100 messages × processing time > Lambda timeout | `batch_size = 10` + `maximum_batching_window_in_seconds = 5` |
| 11 | Python 3.9 runtime (EOL) | Line 68 | No security patches, AWS will deprecate | `runtime = "python3.12"` |
| 12 | No reserved concurrency | Line 67–80 | Lambda scales to 1000 concurrent, overwhelming DynamoDB | `reserved_concurrent_executions = 100` |
| 13 | No X-Ray tracing | Line 67–80 | Cannot trace latency across SQS→Lambda→DynamoDB | `tracing_config { mode = "Active" }` |

---

### 🟡 P2 — Maintainability / Best Practices

| # | Error | Junior's Code | Impact | Senior's Fix |
|---|-------|---------------|--------|--------------|
| 14 | Hardcoded resource names | Lines 15, 25, 39, 63 | No environment isolation | `"${local.name_prefix}-resource-name"` |
| 15 | No tags on any resource | Throughout | Can't track costs, ownership, compliance | `default_tags` + resource-level tags |
| 16 | No `terraform` block / backend | Missing | Local state, no locking, no version pins | S3 backend + DynamoDB locking + version constraints |
| 17 | No variables or outputs | Missing | Can't parameterize or compose with other stacks | Variables with validation + outputs |
| 18 | No CloudWatch alarms | Missing | No alerting on failures, DLQ depth, queue backlog | 3 alarms: errors, DLQ, queue depth |
| 19 | No S3 versioning or lifecycle | Line 62–64 | Can't recover deleted reports, no cost optimization | Versioning + IA at 90d + Glacier at 365d |
| 20 | No `deletion_protection_enabled` | Lines 24–34 | `terraform destroy` deletes financial data table | Enabled for prod environment |

---

## Total: 20 Findings

| Severity | Count | Must fix before prod? |
|----------|-------|-----------------------|
| P0 | 5 | ✅ MUST FIX |
| P1 | 8 | ✅ MUST FIX |
| P2 | 7 | Recommended |
| **Total** | **20** | |

---

## What the Senior's Terraform Adds (that Junior completely missed)

1. **Remote backend** with S3 + DynamoDB state locking
2. **Provider version pinning** (`~> 5.0`)
3. **Variables with validation** blocks
4. **Local values** for DRY naming
5. **Default tags** on provider level
6. **DLQ** with 14-day retention + redrive policy
7. **Encryption** on every resource (SQS, DynamoDB, S3)
8. **Point-in-time recovery** on financial tables
9. **TTL** on idempotency table
10. **S3 hardening** (public access block, versioning, lifecycle, KMS)
11. **Least-privilege IAM** (4 separate focused policies)
12. **ReportBatchItemFailures** on event source mapping
13. **Reserved concurrency** + scaling config
14. **X-Ray tracing**
15. **CloudWatch alarms** (3 critical alarms + SNS topic)
16. **Log group** with retention policy
17. **Outputs** for cross-stack composition
18. **Deletion protection** on prod resources
19. **`source_code_hash`** for proper Lambda updates
20. **Conditional logic** (`var.environment == "prod"`) for env-specific settings

---
