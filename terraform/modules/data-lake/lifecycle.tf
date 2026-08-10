# S3 Lifecycle Policies
# VerticalBroker AWS Data Engineering Platform
#
# Implements cost-optimized storage lifecycle management:
#   - Bronze: Intelligent-Tiering immediately → Glacier Deep Archive after 90 days
#   - Silver: Intelligent-Tiering after 30 days
#   - Gold: Intelligent-Tiering after 60 days
#   - Regulatory Store: No lifecycle transitions (immutable COMPLIANCE mode, 7-year retention)
#
# Also configures S3 Intelligent-Tiering archive access tiers for automatic
# cost optimization without retrieval charges for frequently accessed data.
#
# Requirements: 2.2, 17.2

# ---------------------------------------------------------
# BRONZE BUCKET LIFECYCLE
# Requirement 2.2: Intelligent-Tiering → Glacier Deep Archive after 90 days
# This is the primary cost optimization for the 10 PB data estate
# ---------------------------------------------------------

resource "aws_s3_bucket_lifecycle_configuration" "bronze" {
  bucket = aws_s3_bucket.bronze.id

  # Rule 1: Transition current objects through storage tiers
  rule {
    id     = "bronze-intelligent-tiering-and-glacier"
    status = "Enabled"

    filter {
      prefix = ""
    }

    # Transition to Intelligent-Tiering for automatic hot/warm/cold management
    transition {
      days          = var.bronze_intelligent_tiering_days
      storage_class = "INTELLIGENT_TIERING"
    }

    # Transition to Glacier Deep Archive after configured retention period
    transition {
      days          = var.bronze_glacier_transition_days
      storage_class = "DEEP_ARCHIVE"
    }
  }

  # Rule 2: Clean up incomplete multipart uploads
  rule {
    id     = "bronze-abort-incomplete-multipart"
    status = "Enabled"

    filter {
      prefix = ""
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Rule 3: Expire noncurrent versions for cost control
  # (Object Lock prevents deletion of current versions)
  rule {
    id     = "bronze-noncurrent-version-management"
    status = "Enabled"

    filter {
      prefix = ""
    }

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.bronze]
}

# ---------------------------------------------------------
# S3 INTELLIGENT-TIERING CONFIGURATION FOR BRONZE
# Configures archive access tiers within Intelligent-Tiering
# for objects that stay in IT before the Glacier DA transition
# ---------------------------------------------------------

resource "aws_s3_bucket_intelligent_tiering_configuration" "bronze" {
  bucket = aws_s3_bucket.bronze.id
  name   = "bronze-archive-config"

  tiering {
    access_tier = "ARCHIVE_ACCESS"
    days        = 60
  }

  tiering {
    access_tier = "DEEP_ARCHIVE_ACCESS"
    days        = 90
  }
}

# ---------------------------------------------------------
# SILVER BUCKET LIFECYCLE
# Validated Parquet data with Intelligent-Tiering for cost optimization
# ---------------------------------------------------------

resource "aws_s3_bucket_lifecycle_configuration" "silver" {
  bucket = aws_s3_bucket.silver.id

  # Rule 1: Transition to Intelligent-Tiering after configured period
  rule {
    id     = "silver-intelligent-tiering"
    status = "Enabled"

    filter {
      prefix = ""
    }

    transition {
      days          = var.silver_intelligent_tiering_days
      storage_class = "INTELLIGENT_TIERING"
    }
  }

  # Rule 2: Clean up incomplete multipart uploads
  rule {
    id     = "silver-abort-incomplete-multipart"
    status = "Enabled"

    filter {
      prefix = ""
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Rule 3: Noncurrent version management
  rule {
    id     = "silver-noncurrent-version-management"
    status = "Enabled"

    filter {
      prefix = ""
    }

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.silver]
}

# ---------------------------------------------------------
# GOLD BUCKET LIFECYCLE
# Aggregated datasets optimized for analytics queries
# Longer hot period since Gold data is actively queried
# ---------------------------------------------------------

resource "aws_s3_bucket_lifecycle_configuration" "gold" {
  bucket = aws_s3_bucket.gold.id

  # Rule 1: Transition to Intelligent-Tiering after configured period
  rule {
    id     = "gold-intelligent-tiering"
    status = "Enabled"

    filter {
      prefix = ""
    }

    transition {
      days          = var.gold_intelligent_tiering_days
      storage_class = "INTELLIGENT_TIERING"
    }
  }

  # Rule 2: Clean up incomplete multipart uploads
  rule {
    id     = "gold-abort-incomplete-multipart"
    status = "Enabled"

    filter {
      prefix = ""
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Rule 3: Noncurrent version management
  rule {
    id     = "gold-noncurrent-version-management"
    status = "Enabled"

    filter {
      prefix = ""
    }

    noncurrent_version_transition {
      noncurrent_days = 60
      storage_class   = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.gold]
}

# ---------------------------------------------------------
# REGULATORY STORE BUCKET LIFECYCLE
# Requirement 14.4: No early transitions or deletions allowed
# COMPLIANCE mode Object Lock prevents any modification or deletion
# Only abort incomplete multipart uploads as housekeeping
# ---------------------------------------------------------

resource "aws_s3_bucket_lifecycle_configuration" "regulatory_store" {
  bucket = aws_s3_bucket.regulatory_store.id

  # Only abort incomplete multipart uploads - no transitions or expirations
  # COMPLIANCE mode Object Lock prevents any other lifecycle actions
  rule {
    id     = "regulatory-abort-incomplete-multipart"
    status = "Enabled"

    filter {
      prefix = ""
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.regulatory_store]
}
