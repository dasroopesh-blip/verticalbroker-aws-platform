# KMS Customer-Managed Keys (CMKs) Module
# VerticalBroker AWS Data Engineering Platform
#
# Implements separate CMKs per data classification level with:
# - Automatic annual key rotation (Requirement 2.5)
# - Restrictive key policies granting encrypt/decrypt to specific service roles only (Requirement 14.1)
# - Cross-region key replication for disaster recovery (Requirement 14.2, 16.3)
#
# Data Classification Levels:
#   Public       - Non-sensitive public data (market reference data, public filings)
#   Internal     - Internal platform data (logs, metrics, non-PII metadata)
#   Confidential - Trade data, portfolio data (Bronze/Silver/Gold layers)
#   Restricted   - PII, regulatory data (SSN, account numbers, advisory recommendations)
#
# Requirements: 14.1, 2.5, 14.2

# ---------------------------------------------------------
# LOCAL VALUES
# ---------------------------------------------------------

locals {
  # Map classification levels to their intended service consumers
  # These define which service roles get encrypt/decrypt permissions per key
  default_service_role_arns = {
    Public = [
      "arn:aws:iam::${var.aws_account_id}:role/${var.name_prefix}-market-data-lambda",
      "arn:aws:iam::${var.aws_account_id}:role/${var.name_prefix}-etl-glue",
    ]
    Internal = [
      "arn:aws:iam::${var.aws_account_id}:role/${var.name_prefix}-market-data-lambda",
      "arn:aws:iam::${var.aws_account_id}:role/${var.name_prefix}-etl-glue",
      "arn:aws:iam::${var.aws_account_id}:role/${var.name_prefix}-order-manager-lambda",
    ]
    Confidential = [
      "arn:aws:iam::${var.aws_account_id}:role/${var.name_prefix}-market-data-lambda",
      "arn:aws:iam::${var.aws_account_id}:role/${var.name_prefix}-etl-glue",
      "arn:aws:iam::${var.aws_account_id}:role/${var.name_prefix}-order-manager-lambda",
      "arn:aws:iam::${var.aws_account_id}:role/${var.name_prefix}-wallet-service-lambda",
      "arn:aws:iam::${var.aws_account_id}:role/${var.name_prefix}-advisory-agent-lambda",
    ]
    Restricted = [
      "arn:aws:iam::${var.aws_account_id}:role/${var.name_prefix}-advisory-agent-lambda",
      "arn:aws:iam::${var.aws_account_id}:role/${var.name_prefix}-wallet-service-lambda",
    ]
  }

  # Merge user-provided role ARNs with defaults
  resolved_service_role_arns = {
    for classification in var.data_classifications :
    classification => length(lookup(var.service_role_arns, classification, [])) > 0 ? var.service_role_arns[classification] : lookup(local.default_service_role_arns, classification, [])
  }

  # Admin principals: if none provided, default to account root
  admin_principals = length(var.admin_role_arns) > 0 ? var.admin_role_arns : [
    "arn:aws:iam::${var.aws_account_id}:root"
  ]

  # Classification-specific descriptions for key metadata
  classification_descriptions = {
    Public       = "Encrypts non-sensitive public data (market reference data, public filings)"
    Internal     = "Encrypts internal platform data (logs, metrics, non-PII metadata)"
    Confidential = "Encrypts trade data and portfolio data (Bronze/Silver/Gold layers)"
    Restricted   = "Encrypts PII and regulatory data (SSN, account numbers, advisory logs)"
  }
}

# ---------------------------------------------------------
# KMS KEYS - One per Data Classification Level
# Requirement 14.1: Separate keys per classification
# Requirement 2.5: Annual rotation enabled
# ---------------------------------------------------------

resource "aws_kms_key" "classification" {
  for_each = toset(var.data_classifications)

  description             = "${var.platform_name} CMK for ${each.value} data - ${lookup(local.classification_descriptions, each.value, "Data encryption key")}"
  enable_key_rotation     = var.enable_key_rotation
  deletion_window_in_days = var.key_deletion_window_in_days
  multi_region            = var.enable_cross_region_replication

  # Key policy: restrictive access to admin and designated service roles
  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${var.name_prefix}-kms-${lower(each.value)}-policy"
    Statement = concat(
      # Statement 1: Key Administrators
      [
        {
          Sid    = "KeyAdministration"
          Effect = "Allow"
          Principal = {
            AWS = local.admin_principals
          }
          Action = [
            "kms:Create*",
            "kms:Describe*",
            "kms:Enable*",
            "kms:List*",
            "kms:Put*",
            "kms:Update*",
            "kms:Revoke*",
            "kms:Disable*",
            "kms:Get*",
            "kms:Delete*",
            "kms:TagResource",
            "kms:UntagResource",
            "kms:ScheduleKeyDeletion",
            "kms:CancelKeyDeletion",
            "kms:ReplicateKey",
          ]
          Resource = "*"
        },
      ],
      # Statement 2: Service Role Encrypt/Decrypt
      length(lookup(local.resolved_service_role_arns, each.value, [])) > 0 ? [
        {
          Sid    = "ServiceRoleEncryptDecrypt"
          Effect = "Allow"
          Principal = {
            AWS = local.resolved_service_role_arns[each.value]
          }
          Action = [
            "kms:Encrypt",
            "kms:Decrypt",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey",
            "kms:GenerateDataKeyWithoutPlaintext",
            "kms:DescribeKey",
          ]
          Resource = "*"
        },
      ] : [],
      # Statement 3: Allow AWS services to use the key (for S3, Glue, etc.)
      [
        {
          Sid    = "AllowAWSServiceUsage"
          Effect = "Allow"
          Principal = {
            AWS = "arn:aws:iam::${var.aws_account_id}:root"
          }
          Action = [
            "kms:Encrypt",
            "kms:Decrypt",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*",
            "kms:DescribeKey",
            "kms:CreateGrant",
            "kms:ListGrants",
            "kms:RevokeGrant",
          ]
          Resource = "*"
          Condition = {
            StringEquals = {
              "kms:CallerAccount" = var.aws_account_id
            }
          }
        },
      ],
      # Statement 4: Allow S3, Glue, and other AWS services to create grants
      [
        {
          Sid    = "AllowServiceGrants"
          Effect = "Allow"
          Principal = {
            Service = [
              "s3.amazonaws.com",
              "glue.amazonaws.com",
              "lambda.amazonaws.com",
              "kinesis.amazonaws.com",
              "sqs.amazonaws.com",
              "events.amazonaws.com",
              "logs.amazonaws.com",
            ]
          }
          Action = [
            "kms:Encrypt",
            "kms:Decrypt",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*",
            "kms:DescribeKey",
            "kms:CreateGrant",
          ]
          Resource = "*"
          Condition = {
            StringEquals = {
              "kms:CallerAccount" = var.aws_account_id
            }
          }
        },
      ],
      # Statement 5: Deny key usage without TLS (in-transit encryption enforcement)
      [
        {
          Sid       = "DenyNonTLSAccess"
          Effect    = "Deny"
          Principal = "*"
          Action    = "kms:*"
          Resource  = "*"
          Condition = {
            Bool = {
              "aws:SecureTransport" = "false"
            }
          }
        },
      ]
    )
  })

  tags = merge(var.mandatory_tags, {
    Name               = "${var.name_prefix}-kms-${lower(each.value)}"
    DataClassification = each.value
    Service            = "kms"
    Purpose            = "data-encryption"
  })
}

# ---------------------------------------------------------
# KMS KEY ALIASES
# Human-readable aliases for each classification key
# ---------------------------------------------------------

resource "aws_kms_alias" "classification" {
  for_each = toset(var.data_classifications)

  name          = "alias/${var.name_prefix}-${lower(each.value)}"
  target_key_id = aws_kms_key.classification[each.value].key_id
}

# ---------------------------------------------------------
# CROSS-REGION KEY REPLICAS (DR)
# Requirement 14.2, 16.3: Replicate keys to DR region for cross-region access
# ---------------------------------------------------------

resource "aws_kms_replica_key" "dr" {
  for_each = var.enable_cross_region_replication ? toset(var.data_classifications) : toset([])

  provider = aws.dr

  description             = "DR replica of ${var.platform_name} CMK for ${each.value} data in ${var.dr_region}"
  primary_key_arn         = aws_kms_key.classification[each.value].arn
  deletion_window_in_days = var.key_deletion_window_in_days

  # Replica key policy mirrors primary key policy
  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${var.name_prefix}-kms-${lower(each.value)}-dr-policy"
    Statement = concat(
      # Key Administration
      [
        {
          Sid    = "KeyAdministration"
          Effect = "Allow"
          Principal = {
            AWS = local.admin_principals
          }
          Action = [
            "kms:Create*",
            "kms:Describe*",
            "kms:Enable*",
            "kms:List*",
            "kms:Put*",
            "kms:Update*",
            "kms:Revoke*",
            "kms:Disable*",
            "kms:Get*",
            "kms:Delete*",
            "kms:TagResource",
            "kms:UntagResource",
            "kms:ScheduleKeyDeletion",
            "kms:CancelKeyDeletion",
          ]
          Resource = "*"
        },
      ],
      # Service Role Encrypt/Decrypt in DR region
      length(lookup(local.resolved_service_role_arns, each.value, [])) > 0 ? [
        {
          Sid    = "ServiceRoleEncryptDecrypt"
          Effect = "Allow"
          Principal = {
            AWS = local.resolved_service_role_arns[each.value]
          }
          Action = [
            "kms:Encrypt",
            "kms:Decrypt",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey",
            "kms:GenerateDataKeyWithoutPlaintext",
            "kms:DescribeKey",
          ]
          Resource = "*"
        },
      ] : [],
      # Allow AWS services
      [
        {
          Sid    = "AllowAWSServiceUsage"
          Effect = "Allow"
          Principal = {
            AWS = "arn:aws:iam::${var.aws_account_id}:root"
          }
          Action = [
            "kms:Encrypt",
            "kms:Decrypt",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*",
            "kms:DescribeKey",
            "kms:CreateGrant",
            "kms:ListGrants",
            "kms:RevokeGrant",
          ]
          Resource = "*"
          Condition = {
            StringEquals = {
              "kms:CallerAccount" = var.aws_account_id
            }
          }
        },
      ],
      # Allow AWS service grants
      [
        {
          Sid    = "AllowServiceGrants"
          Effect = "Allow"
          Principal = {
            Service = [
              "s3.amazonaws.com",
              "glue.amazonaws.com",
              "lambda.amazonaws.com",
              "kinesis.amazonaws.com",
              "sqs.amazonaws.com",
              "events.amazonaws.com",
              "logs.amazonaws.com",
            ]
          }
          Action = [
            "kms:Encrypt",
            "kms:Decrypt",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*",
            "kms:DescribeKey",
            "kms:CreateGrant",
          ]
          Resource = "*"
          Condition = {
            StringEquals = {
              "kms:CallerAccount" = var.aws_account_id
            }
          }
        },
      ],
      # Deny non-TLS access
      [
        {
          Sid       = "DenyNonTLSAccess"
          Effect    = "Deny"
          Principal = "*"
          Action    = "kms:*"
          Resource  = "*"
          Condition = {
            Bool = {
              "aws:SecureTransport" = "false"
            }
          }
        },
      ]
    )
  })

  tags = merge(var.mandatory_tags, {
    Name               = "${var.name_prefix}-kms-${lower(each.value)}-dr"
    DataClassification = each.value
    Service            = "kms"
    Purpose            = "data-encryption-dr-replica"
    PrimaryRegion      = var.aws_region
  })
}

# ---------------------------------------------------------
# DR REGION KEY ALIASES
# ---------------------------------------------------------

resource "aws_kms_alias" "dr" {
  for_each = var.enable_cross_region_replication ? toset(var.data_classifications) : toset([])

  provider = aws.dr

  name          = "alias/${var.name_prefix}-${lower(each.value)}"
  target_key_id = aws_kms_replica_key.dr[each.value].key_id
}
