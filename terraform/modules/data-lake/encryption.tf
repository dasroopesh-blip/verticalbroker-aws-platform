# S3 Bucket Encryption Configuration
# VerticalBroker AWS Data Engineering Platform
#
# Links KMS Customer-Managed Keys (CMKs) per bucket data classification:
#   - Bronze: Confidential CMK (trade data in raw form)
#   - Silver: Confidential CMK (validated trade data)
#   - Gold: Confidential CMK (aggregated business datasets)
#   - Regulatory Store: Restricted CMK (PII, audit data, advisory logs)
#
# All buckets enforce aws:kms server-side encryption with bucket keys enabled
# for reduced KMS API call costs at scale (10 PB estate).
#
# Requirements: 2.5 (KMS CMK encryption at rest), 14.1 (separate keys per classification)

# ---------------------------------------------------------
# BRONZE BUCKET ENCRYPTION
# Data Classification: Confidential
# Encrypts raw market data from Bloomberg B-Pipe and Thomson Reuters
# ---------------------------------------------------------

resource "aws_s3_bucket_server_side_encryption_configuration" "bronze" {
  bucket = aws_s3_bucket.bronze.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_confidential_key_arn
    }
    bucket_key_enabled = true
  }
}

# ---------------------------------------------------------
# SILVER BUCKET ENCRYPTION
# Data Classification: Confidential
# Encrypts validated Parquet/Snappy datasets
# ---------------------------------------------------------

resource "aws_s3_bucket_server_side_encryption_configuration" "silver" {
  bucket = aws_s3_bucket.silver.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_confidential_key_arn
    }
    bucket_key_enabled = true
  }
}

# ---------------------------------------------------------
# GOLD BUCKET ENCRYPTION
# Data Classification: Confidential
# Encrypts aggregated business datasets (trade summaries, portfolios, risk)
# ---------------------------------------------------------

resource "aws_s3_bucket_server_side_encryption_configuration" "gold" {
  bucket = aws_s3_bucket.gold.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_confidential_key_arn
    }
    bucket_key_enabled = true
  }
}

# ---------------------------------------------------------
# REGULATORY STORE BUCKET ENCRYPTION
# Data Classification: Restricted
# Encrypts FINRA/SEC audit data, advisory recommendations, trade records
# Uses Restricted-level CMK with stricter access controls
# ---------------------------------------------------------

resource "aws_s3_bucket_server_side_encryption_configuration" "regulatory_store" {
  bucket = aws_s3_bucket.regulatory_store.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_restricted_key_arn
    }
    bucket_key_enabled = true
  }
}
