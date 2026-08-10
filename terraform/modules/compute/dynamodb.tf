# DynamoDB Tables - VerticalBroker AWS Data Engineering Platform
#
# Defines DynamoDB tables supporting Lambda compute functions:
#   - IdempotencyStore: Idempotency tokens with TTL (Requirement 7.5)
#   - CircuitBreakerState: Distributed circuit breaker state (Requirement 16.5)
#   - Orders: Trade order records (Requirement 7.1)
#   - OrderOutbox: Transactional outbox with DynamoDB Streams (Requirement 6.7)
#   - Portfolio: Client portfolio positions (Requirement 7.1)
#
# Requirements: 7.1, 7.2, 7.5, 16.5
# All tables use PAY_PER_REQUEST (on-demand) billing for auto-scaling
# All tables encrypted with KMS CMK and have point-in-time recovery enabled

# =============================================================================
# IDEMPOTENCY STORE TABLE
# PK: idempotency_key (String)
# TTL: expiration (Number - epoch seconds)
# Used by Lambda Powertools idempotency utility across all functions
# =============================================================================

resource "aws_dynamodb_table" "idempotency_store" {
  name         = "${var.name_prefix}-idempotency-store"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "idempotency_key"

  attribute {
    name = "idempotency_key"
    type = "S"
  }

  # TTL for automatic cleanup of expired idempotency records (24h default)
  ttl {
    attribute_name = "expiration"
    enabled        = true
  }

  # Encryption at rest using KMS CMK (Requirement 14.1)
  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_confidential_key_arn
  }

  # Point-in-time recovery for disaster recovery
  point_in_time_recovery {
    enabled = true
  }

  # Deletion protection for production environments
  deletion_protection_enabled = var.environment == "production" ? true : false

  tags = merge(local.dynamodb_tags, {
    Table              = "IdempotencyStore"
    DataClassification = "Internal"
    Purpose            = "Idempotency token storage for exactly-once processing"
  })
}

# =============================================================================
# CIRCUIT BREAKER STATE TABLE
# PK: service_name (String)
# Stores circuit breaker state for distributed Lambda functions
# =============================================================================

resource "aws_dynamodb_table" "circuit_breaker_state" {
  name         = "${var.name_prefix}-circuit-breaker-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "service_name"

  attribute {
    name = "service_name"
    type = "S"
  }

  # Encryption at rest using KMS CMK
  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_confidential_key_arn
  }

  # Point-in-time recovery
  point_in_time_recovery {
    enabled = true
  }

  deletion_protection_enabled = var.environment == "production" ? true : false

  tags = merge(local.dynamodb_tags, {
    Table              = "CircuitBreakerState"
    DataClassification = "Internal"
    Purpose            = "Distributed circuit breaker state management"
  })
}

# =============================================================================
# ORDERS TABLE
# PK: order_id (String)
# Stores trade order records for the Order Manager service
# =============================================================================

resource "aws_dynamodb_table" "orders" {
  name         = "${var.name_prefix}-orders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "order_id"

  attribute {
    name = "order_id"
    type = "S"
  }

  # Global Secondary Index for client-based lookups
  global_secondary_index {
    name            = "client-index"
    hash_key        = "client_id"
    range_key       = "order_timestamp"
    projection_type = "ALL"
  }

  attribute {
    name = "client_id"
    type = "S"
  }

  attribute {
    name = "order_timestamp"
    type = "S"
  }

  # Encryption at rest using KMS CMK (Requirement 14.1)
  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_confidential_key_arn
  }

  # Point-in-time recovery
  point_in_time_recovery {
    enabled = true
  }

  deletion_protection_enabled = var.environment == "production" ? true : false

  tags = merge(local.dynamodb_tags, {
    Table              = "Orders"
    DataClassification = "Confidential"
    Purpose            = "Trade order lifecycle records"
  })
}

# =============================================================================
# ORDER OUTBOX TABLE
# PK: event_id (String)
# DynamoDB Streams enabled (NEW_AND_OLD_IMAGES) for transactional outbox pattern
# Outbox Publisher Lambda reads stream to publish events to EventBridge
# =============================================================================

resource "aws_dynamodb_table" "order_outbox" {
  name         = "${var.name_prefix}-order-outbox"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  # Enable DynamoDB Streams for the outbox publisher
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  # TTL for automatic cleanup of published outbox entries
  ttl {
    attribute_name = "expiration"
    enabled        = true
  }

  # Encryption at rest using KMS CMK
  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_confidential_key_arn
  }

  # Point-in-time recovery
  point_in_time_recovery {
    enabled = true
  }

  deletion_protection_enabled = var.environment == "production" ? true : false

  tags = merge(local.dynamodb_tags, {
    Table              = "OrderOutbox"
    DataClassification = "Confidential"
    Purpose            = "Transactional outbox for reliable event publishing"
  })
}

# =============================================================================
# PORTFOLIO TABLE
# PK: client_id (String), SK: account_id (String)
# Stores client portfolio positions and cash balances
# =============================================================================

resource "aws_dynamodb_table" "portfolio" {
  name         = "${var.name_prefix}-portfolio"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "client_id"
  range_key    = "account_id"

  attribute {
    name = "client_id"
    type = "S"
  }

  attribute {
    name = "account_id"
    type = "S"
  }

  # Encryption at rest using KMS CMK (Requirement 14.1)
  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_confidential_key_arn
  }

  # Point-in-time recovery
  point_in_time_recovery {
    enabled = true
  }

  deletion_protection_enabled = var.environment == "production" ? true : false

  tags = merge(local.dynamodb_tags, {
    Table              = "Portfolio"
    DataClassification = "Confidential"
    Purpose            = "Client portfolio positions and cash balances"
  })
}

# =============================================================================
# LOCAL VALUES
# =============================================================================

locals {
  dynamodb_tags = merge(var.mandatory_tags, {
    Service = "Compute"
    Module  = "DynamoDB"
  })
}

# =============================================================================
# VARIABLES (DynamoDB-specific)
# =============================================================================

variable "kms_confidential_key_arn" {
  description = "KMS key ARN for Confidential data classification (DynamoDB encryption)"
  type        = string
}
