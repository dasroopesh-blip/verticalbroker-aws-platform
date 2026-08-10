# S3 Cross-Region Replication (CRR) for Disaster Recovery
# VerticalBroker AWS Data Engineering Platform
#
# Implements S3 CRR from primary region (us-east-1) to DR region (us-west-2)
# for Bronze layer, Gold layer, and Terraform state buckets.
#
# Requirements: 2.6 (Replicate Bronze data to secondary region within 15 minutes)
# Requirements: 16.3 (Replicate Gold data and Terraform state to secondary region)
#
# Design: IAM replication role with least-privilege, prefix-based replication rules,
#         replica KMS keys, destination buckets in DR region, CloudWatch replication
#         lag monitoring with alarm at >15 minutes threshold.

# ---------------------------------------------------------
# LOCAL VALUES
# ---------------------------------------------------------

locals {
  # Buckets requiring cross-region replication
  replication_buckets = var.enable_cross_region_replication ? {
    bronze = {
      source_bucket_id  = aws_s3_bucket.bronze.id
      source_bucket_arn = aws_s3_bucket.bronze.arn
      destination_name  = "${var.name_prefix}-bronze-dr"
      kms_key_arn       = var.kms_confidential_key_arn
      dr_kms_key_arn    = var.kms_confidential_dr_key_arn
      priority          = 1
      prefix            = ""
      storage_class     = "STANDARD_IA"
    }
    gold = {
      source_bucket_id  = aws_s3_bucket.gold.id
      source_bucket_arn = aws_s3_bucket.gold.arn
      destination_name  = "${var.name_prefix}-gold-dr"
      kms_key_arn       = var.kms_confidential_key_arn
      dr_kms_key_arn    = var.kms_confidential_dr_key_arn
      priority          = 2
      prefix            = ""
      storage_class     = "STANDARD"
    }
    terraform_state = {
      source_bucket_id  = var.terraform_state_bucket_id
      source_bucket_arn = var.terraform_state_bucket_arn
      destination_name  = "${var.name_prefix}-tfstate-dr"
      kms_key_arn       = var.kms_internal_key_arn
      dr_kms_key_arn    = var.kms_internal_dr_key_arn
      priority          = 3
      prefix            = ""
      storage_class     = "STANDARD"
    }
  } : {}

  replication_common_tags = merge(var.mandatory_tags, {
    Service = "data-lake"
    Purpose = "disaster-recovery-replication"
  })
}

# ---------------------------------------------------------
# IAM ROLE FOR S3 REPLICATION
# Least-privilege role allowing S3 to replicate objects across regions
# Requirement 13.4: No wildcard resource permissions
# ---------------------------------------------------------

resource "aws_iam_role" "s3_replication" {
  count = var.enable_cross_region_replication ? 1 : 0

  name = "${var.name_prefix}-s3-crr-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.replication_common_tags, {
    Name = "${var.name_prefix}-s3-crr-role"
  })
}

resource "aws_iam_policy" "s3_replication" {
  count = var.enable_cross_region_replication ? 1 : 0

  name        = "${var.name_prefix}-s3-crr-policy"
  description = "Allows S3 cross-region replication for Bronze, Gold, and Terraform state buckets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SourceBucketGetReplicationConfiguration"
        Effect = "Allow"
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket",
        ]
        Resource = [
          for key, bucket in local.replication_buckets : bucket.source_bucket_arn
        ]
      },
      {
        Sid    = "SourceBucketGetObjectForReplication"
        Effect = "Allow"
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging",
        ]
        Resource = [
          for key, bucket in local.replication_buckets : "${bucket.source_bucket_arn}/*"
        ]
      },
      {
        Sid    = "DestinationBucketReplicateObjects"
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags",
          "s3:ObjectOwnerOverrideToBucketOwner",
        ]
        Resource = [
          for key, bucket in local.replication_buckets :
          "arn:aws:s3:::${bucket.destination_name}/*"
        ]
      },
      {
        Sid    = "SourceKMSDecrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = distinct([
          for key, bucket in local.replication_buckets : bucket.kms_key_arn
        ])
      },
      {
        Sid    = "DestinationKMSEncrypt"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = distinct([
          for key, bucket in local.replication_buckets : bucket.dr_kms_key_arn
        ])
      },
    ]
  })

  tags = merge(local.replication_common_tags, {
    Name = "${var.name_prefix}-s3-crr-policy"
  })
}

resource "aws_iam_role_policy_attachment" "s3_replication" {
  count = var.enable_cross_region_replication ? 1 : 0

  role       = aws_iam_role.s3_replication[0].name
  policy_arn = aws_iam_policy.s3_replication[0].arn
}

# ---------------------------------------------------------
# DESTINATION BUCKETS IN DR REGION
# Created in us-west-2 using aws.dr provider alias
# ---------------------------------------------------------

resource "aws_s3_bucket" "dr_destination" {
  for_each = local.replication_buckets

  provider = aws.dr

  bucket = each.value.destination_name

  tags = merge(local.replication_common_tags, {
    Name               = each.value.destination_name
    DataClassification = "Confidential"
    ReplicaOf          = each.value.source_bucket_id
    Region             = var.dr_region
  })
}

resource "aws_s3_bucket_versioning" "dr_destination" {
  for_each = local.replication_buckets

  provider = aws.dr

  bucket = aws_s3_bucket.dr_destination[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dr_destination" {
  for_each = local.replication_buckets

  provider = aws.dr

  bucket = aws_s3_bucket.dr_destination[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = each.value.dr_kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "dr_destination" {
  for_each = local.replication_buckets

  provider = aws.dr

  bucket = aws_s3_bucket.dr_destination[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------
# S3 REPLICATION CONFIGURATION
# One replication configuration per source bucket with rules
# targeting the corresponding DR destination bucket
# ---------------------------------------------------------

resource "aws_s3_bucket_replication_configuration" "bronze" {
  count = var.enable_cross_region_replication ? 1 : 0

  depends_on = [aws_s3_bucket_versioning.dr_destination]

  role   = aws_iam_role.s3_replication[0].arn
  bucket = aws_s3_bucket.bronze.id

  rule {
    id     = "bronze-full-replication"
    status = "Enabled"

    filter {}

    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket        = aws_s3_bucket.dr_destination["bronze"].arn
      storage_class = "STANDARD_IA"

      encryption_configuration {
        replica_kms_key_id = var.kms_confidential_dr_key_arn
      }

      metrics {
        status = "Enabled"
        event_threshold {
          minutes = 15
        }
      }

      replication_time {
        status = "Enabled"
        time {
          minutes = 15
        }
      }
    }

    source_selection_criteria {
      sse_kms_encrypted_objects {
        status = "Enabled"
      }
    }
  }
}

resource "aws_s3_bucket_replication_configuration" "gold" {
  count = var.enable_cross_region_replication ? 1 : 0

  depends_on = [aws_s3_bucket_versioning.dr_destination]

  role   = aws_iam_role.s3_replication[0].arn
  bucket = aws_s3_bucket.gold.id

  rule {
    id     = "gold-full-replication"
    status = "Enabled"

    filter {}

    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket        = aws_s3_bucket.dr_destination["gold"].arn
      storage_class = "STANDARD"

      encryption_configuration {
        replica_kms_key_id = var.kms_confidential_dr_key_arn
      }

      metrics {
        status = "Enabled"
        event_threshold {
          minutes = 15
        }
      }

      replication_time {
        status = "Enabled"
        time {
          minutes = 15
        }
      }
    }

    source_selection_criteria {
      sse_kms_encrypted_objects {
        status = "Enabled"
      }
    }
  }
}

resource "aws_s3_bucket_replication_configuration" "terraform_state" {
  count = var.enable_cross_region_replication ? 1 : 0

  depends_on = [aws_s3_bucket_versioning.dr_destination]

  role   = aws_iam_role.s3_replication[0].arn
  bucket = var.terraform_state_bucket_id

  rule {
    id     = "tfstate-full-replication"
    status = "Enabled"

    filter {}

    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket        = aws_s3_bucket.dr_destination["terraform_state"].arn
      storage_class = "STANDARD"

      encryption_configuration {
        replica_kms_key_id = var.kms_internal_dr_key_arn
      }

      metrics {
        status = "Enabled"
        event_threshold {
          minutes = 15
        }
      }

      replication_time {
        status = "Enabled"
        time {
          minutes = 15
        }
      }
    }

    source_selection_criteria {
      sse_kms_encrypted_objects {
        status = "Enabled"
      }
    }
  }
}

# ---------------------------------------------------------
# CLOUDWATCH REPLICATION LAG MONITORING
# Requirement 2.6: Target <15 minutes replication lag for Bronze data
# S3 Replication Time Control (RTC) emits ReplicationLatency metric
# ---------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "bronze_replication_lag" {
  count = var.enable_cross_region_replication ? 1 : 0

  alarm_name          = "${var.name_prefix}-bronze-replication-lag"
  alarm_description   = "S3 CRR replication lag for Bronze bucket exceeds 15 minutes (Requirement 2.6)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ReplicationLatency"
  namespace           = "AWS/S3"
  period              = 300
  statistic           = "Maximum"
  threshold           = 900
  treat_missing_data  = "notBreaching"

  dimensions = {
    SourceBucket      = aws_s3_bucket.bronze.id
    DestinationBucket = aws_s3_bucket.dr_destination["bronze"].id
    RuleId            = "bronze-full-replication"
  }

  alarm_actions = var.monitoring_sns_topic_arn != "" ? [var.monitoring_sns_topic_arn] : []
  ok_actions    = var.monitoring_sns_topic_arn != "" ? [var.monitoring_sns_topic_arn] : []

  tags = merge(local.replication_common_tags, {
    Name     = "${var.name_prefix}-bronze-replication-lag-alarm"
    Severity = "HIGH"
  })
}

resource "aws_cloudwatch_metric_alarm" "gold_replication_lag" {
  count = var.enable_cross_region_replication ? 1 : 0

  alarm_name          = "${var.name_prefix}-gold-replication-lag"
  alarm_description   = "S3 CRR replication lag for Gold bucket exceeds 15 minutes (Requirement 16.3)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ReplicationLatency"
  namespace           = "AWS/S3"
  period              = 300
  statistic           = "Maximum"
  threshold           = 900
  treat_missing_data  = "notBreaching"

  dimensions = {
    SourceBucket      = aws_s3_bucket.gold.id
    DestinationBucket = aws_s3_bucket.dr_destination["gold"].id
    RuleId            = "gold-full-replication"
  }

  alarm_actions = var.monitoring_sns_topic_arn != "" ? [var.monitoring_sns_topic_arn] : []
  ok_actions    = var.monitoring_sns_topic_arn != "" ? [var.monitoring_sns_topic_arn] : []

  tags = merge(local.replication_common_tags, {
    Name     = "${var.name_prefix}-gold-replication-lag-alarm"
    Severity = "HIGH"
  })
}

resource "aws_cloudwatch_metric_alarm" "terraform_state_replication_lag" {
  count = var.enable_cross_region_replication ? 1 : 0

  alarm_name          = "${var.name_prefix}-tfstate-replication-lag"
  alarm_description   = "S3 CRR replication lag for Terraform state bucket exceeds 15 minutes (Requirement 16.3)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ReplicationLatency"
  namespace           = "AWS/S3"
  period              = 300
  statistic           = "Maximum"
  threshold           = 900
  treat_missing_data  = "notBreaching"

  dimensions = {
    SourceBucket      = var.terraform_state_bucket_id
    DestinationBucket = aws_s3_bucket.dr_destination["terraform_state"].id
    RuleId            = "tfstate-full-replication"
  }

  alarm_actions = var.monitoring_sns_topic_arn != "" ? [var.monitoring_sns_topic_arn] : []
  ok_actions    = var.monitoring_sns_topic_arn != "" ? [var.monitoring_sns_topic_arn] : []

  tags = merge(local.replication_common_tags, {
    Name     = "${var.name_prefix}-tfstate-replication-lag-alarm"
    Severity = "MEDIUM"
  })
}

# ---------------------------------------------------------
# CLOUDWATCH DASHBOARD FOR REPLICATION MONITORING
# ---------------------------------------------------------

resource "aws_cloudwatch_dashboard" "replication" {
  count = var.enable_cross_region_replication ? 1 : 0

  dashboard_name = "${var.name_prefix}-s3-replication"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/S3", "ReplicationLatency", "SourceBucket", aws_s3_bucket.bronze.id, "DestinationBucket", aws_s3_bucket.dr_destination["bronze"].id, "RuleId", "bronze-full-replication"],
            ["AWS/S3", "ReplicationLatency", "SourceBucket", aws_s3_bucket.gold.id, "DestinationBucket", aws_s3_bucket.dr_destination["gold"].id, "RuleId", "gold-full-replication"],
            ["AWS/S3", "ReplicationLatency", "SourceBucket", var.terraform_state_bucket_id, "DestinationBucket", aws_s3_bucket.dr_destination["terraform_state"].id, "RuleId", "tfstate-full-replication"],
          ]
          title  = "S3 Replication Latency (seconds)"
          region = var.aws_region
          period = 300
          stat   = "Maximum"
          annotations = {
            horizontal = [
              {
                value = 900
                label = "SLA Threshold (15 min)"
                color = "#d62728"
              }
            ]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/S3", "OperationsPendingReplication", "SourceBucket", aws_s3_bucket.bronze.id, "DestinationBucket", aws_s3_bucket.dr_destination["bronze"].id, "RuleId", "bronze-full-replication"],
            ["AWS/S3", "OperationsPendingReplication", "SourceBucket", aws_s3_bucket.gold.id, "DestinationBucket", aws_s3_bucket.dr_destination["gold"].id, "RuleId", "gold-full-replication"],
            ["AWS/S3", "OperationsPendingReplication", "SourceBucket", var.terraform_state_bucket_id, "DestinationBucket", aws_s3_bucket.dr_destination["terraform_state"].id, "RuleId", "tfstate-full-replication"],
          ]
          title  = "Operations Pending Replication"
          region = var.aws_region
          period = 300
          stat   = "Average"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/S3", "BytesPendingReplication", "SourceBucket", aws_s3_bucket.bronze.id, "DestinationBucket", aws_s3_bucket.dr_destination["bronze"].id, "RuleId", "bronze-full-replication"],
            ["AWS/S3", "BytesPendingReplication", "SourceBucket", aws_s3_bucket.gold.id, "DestinationBucket", aws_s3_bucket.dr_destination["gold"].id, "RuleId", "gold-full-replication"],
            ["AWS/S3", "BytesPendingReplication", "SourceBucket", var.terraform_state_bucket_id, "DestinationBucket", aws_s3_bucket.dr_destination["terraform_state"].id, "RuleId", "tfstate-full-replication"],
          ]
          title  = "Bytes Pending Replication"
          region = var.aws_region
          period = 300
          stat   = "Average"
        }
      },
    ]
  })
}
