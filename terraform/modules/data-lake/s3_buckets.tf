# S3 Data Lake Buckets
# VerticalBroker AWS Data Engineering Platform
#
# Implements the medallion architecture with four S3 buckets:
#   - Bronze (vb-bronze-{env}): Raw immutable data, Hive-partitioned, Object Lock Governance
#   - Silver (vb-silver-{env}): Validated Parquet/Snappy data
#   - Gold (vb-gold-{env}): Aggregated business datasets
#   - Regulatory Store (vb-regulatory-store-{env}): COMPLIANCE mode Object Lock, 7-year FINRA retention
#
# All buckets enforce:
#   - Block public access (BucketOwnerEnforced)
#   - S3 Versioning enabled
#   - Server-side encryption with KMS CMK
#   - TLS-only access via bucket policy
#
# Requirements: 2.1, 2.2, 2.3, 2.5, 14.4, 13.5

# ---------------------------------------------------------
# LOCAL VALUES
# ---------------------------------------------------------

locals {
  # Bucket names: allow override or use default convention
  bronze_bucket_name     = var.bronze_bucket_name != "" ? var.bronze_bucket_name : "vb-bronze-${var.environment}"
  silver_bucket_name     = var.silver_bucket_name != "" ? var.silver_bucket_name : "vb-silver-${var.environment}"
  gold_bucket_name       = var.gold_bucket_name != "" ? var.gold_bucket_name : "vb-gold-${var.environment}"
  regulatory_bucket_name = var.regulatory_bucket_name != "" ? var.regulatory_bucket_name : "vb-regulatory-store-${var.environment}"

  # Hive-style partition prefixes for documentation and S3 inventory configuration
  # Actual partitioning is source=X/year=YYYY/month=MM/day=DD/hour=HH
  hive_partition_structure = "source={source}/year={year}/month={month}/day={day}/hour={hour}"
}

# ---------------------------------------------------------
# BRONZE BUCKET - Raw Immutable Data
# Requirement 2.1: Hive-style partitioned storage for all raw ingested data
# Requirement 2.3: Versioning + Object Lock (Governance mode) for regulatory compliance
# ---------------------------------------------------------

resource "aws_s3_bucket" "bronze" {
  bucket              = local.bronze_bucket_name
  object_lock_enabled = true

  tags = merge(var.mandatory_tags, {
    Name               = local.bronze_bucket_name
    DataClassification = "Confidential"
    Service            = "data-lake"
    Purpose            = "bronze-layer-raw-data"
    Compliance         = "FINRA-4511"
    PartitionStrategy  = local.hive_partition_structure
  })
}

resource "aws_s3_bucket_versioning" "bronze" {
  bucket = aws_s3_bucket.bronze.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "bronze" {
  bucket = aws_s3_bucket.bronze.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.bronze_object_lock_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.bronze]
}

resource "aws_s3_bucket_public_access_block" "bronze" {
  bucket = aws_s3_bucket.bronze.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "bronze" {
  bucket = aws_s3_bucket.bronze.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_policy" "bronze" {
  bucket = aws_s3_bucket.bronze.id

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${local.bronze_bucket_name}-tls-only-policy"
    Statement = [
      {
        Sid       = "DenyNonTLSAccess"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.bronze.arn,
          "${aws_s3_bucket.bronze.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
      {
        Sid       = "DenyIncorrectEncryptionHeader"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.bronze.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = "aws:kms"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.bronze]
}

# ---------------------------------------------------------
# SILVER BUCKET - Validated Parquet/Snappy Data
# Stores cleansed, deduplicated, schema-enforced data
# ---------------------------------------------------------

resource "aws_s3_bucket" "silver" {
  bucket = local.silver_bucket_name

  tags = merge(var.mandatory_tags, {
    Name               = local.silver_bucket_name
    DataClassification = "Confidential"
    Service            = "data-lake"
    Purpose            = "silver-layer-validated-data"
    Compliance         = "FINRA-4511"
  })
}

resource "aws_s3_bucket_versioning" "silver" {
  bucket = aws_s3_bucket.silver.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "silver" {
  bucket = aws_s3_bucket.silver.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "silver" {
  bucket = aws_s3_bucket.silver.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_policy" "silver" {
  bucket = aws_s3_bucket.silver.id

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${local.silver_bucket_name}-tls-only-policy"
    Statement = [
      {
        Sid       = "DenyNonTLSAccess"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.silver.arn,
          "${aws_s3_bucket.silver.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
      {
        Sid       = "DenyIncorrectEncryptionHeader"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.silver.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = "aws:kms"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.silver]
}

# ---------------------------------------------------------
# GOLD BUCKET - Aggregated Business Datasets
# Optimized for analytics, ML training, and regulatory reporting
# ---------------------------------------------------------

resource "aws_s3_bucket" "gold" {
  bucket = local.gold_bucket_name

  tags = merge(var.mandatory_tags, {
    Name               = local.gold_bucket_name
    DataClassification = "Confidential"
    Service            = "data-lake"
    Purpose            = "gold-layer-aggregated-data"
    Compliance         = "FINRA-4511"
  })
}

resource "aws_s3_bucket_versioning" "gold" {
  bucket = aws_s3_bucket.gold.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "gold" {
  bucket = aws_s3_bucket.gold.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "gold" {
  bucket = aws_s3_bucket.gold.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_policy" "gold" {
  bucket = aws_s3_bucket.gold.id

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${local.gold_bucket_name}-tls-only-policy"
    Statement = [
      {
        Sid       = "DenyNonTLSAccess"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.gold.arn,
          "${aws_s3_bucket.gold.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
      {
        Sid       = "DenyIncorrectEncryptionHeader"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.gold.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = "aws:kms"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.gold]
}

# ---------------------------------------------------------
# REGULATORY STORE BUCKET - Immutable FINRA/SEC Compliance Data
# Requirement 14.4: COMPLIANCE mode Object Lock, 7-year retention per FINRA Rule 4511
# Write-once storage for audit trails, trade records, advisory logs
# ---------------------------------------------------------

resource "aws_s3_bucket" "regulatory_store" {
  bucket              = local.regulatory_bucket_name
  object_lock_enabled = true

  tags = merge(var.mandatory_tags, {
    Name               = local.regulatory_bucket_name
    DataClassification = "Restricted"
    Service            = "data-lake"
    Purpose            = "regulatory-store-compliance-data"
    Compliance         = "FINRA-4511,SEC,SOC2-TypeII"
    RetentionYears     = tostring(var.regulatory_retention_years)
  })
}

resource "aws_s3_bucket_versioning" "regulatory_store" {
  bucket = aws_s3_bucket.regulatory_store.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "regulatory_store" {
  bucket = aws_s3_bucket.regulatory_store.id

  rule {
    default_retention {
      mode  = "COMPLIANCE"
      years = var.regulatory_retention_years
    }
  }

  depends_on = [aws_s3_bucket_versioning.regulatory_store]
}

resource "aws_s3_bucket_public_access_block" "regulatory_store" {
  bucket = aws_s3_bucket.regulatory_store.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "regulatory_store" {
  bucket = aws_s3_bucket.regulatory_store.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_policy" "regulatory_store" {
  bucket = aws_s3_bucket.regulatory_store.id

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${local.regulatory_bucket_name}-tls-only-policy"
    Statement = [
      {
        Sid       = "DenyNonTLSAccess"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.regulatory_store.arn,
          "${aws_s3_bucket.regulatory_store.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
      {
        Sid       = "DenyIncorrectEncryptionHeader"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.regulatory_store.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = "aws:kms"
          }
        }
      },
      {
        Sid       = "DenyObjectLockOverride"
        Effect    = "Deny"
        Principal = "*"
        Action = [
          "s3:PutObjectRetention",
          "s3:PutObjectLegalHold"
        ]
        Resource  = "${aws_s3_bucket.regulatory_store.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-object-lock-mode" = "COMPLIANCE"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.regulatory_store]
}
