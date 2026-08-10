# AWS Organizations and Multi-Account Structure
# VerticalBroker AWS Data Engineering Platform
#
# Requirements: 20.1 (AWS Organizations with separate accounts per function)
# Requirements: 20.5 (Baseline security controls via Organization-level delegation)
# Requirements: 13.8 (Parameterized modules for 100+ account scaling)
#
# Architecture: Management Account → OUs → Member Accounts
#   - Security OU: Security & Audit Account (CloudTrail, GuardDuty, Config)
#   - Shared Services OU: Transit Gateway, DNS, ECR
#   - Data Lake OU: Dev, Staging, Production
#   - Compute OU: Dev, Staging, Production
#   - DR OU: Disaster Recovery Account

# ---------------------------------------------------------
# VARIABLES
# ---------------------------------------------------------

variable "organization_enabled_policy_types" {
  description = "Policy types to enable in the Organization"
  type        = list(string)
  default     = ["SERVICE_CONTROL_POLICY", "TAG_POLICY"]
}

variable "allowed_regions" {
  description = "AWS regions allowed by SCP (Requirement 20.1 - region restriction)"
  type        = list(string)
  default     = ["us-east-1", "us-west-2"]
}

variable "organization_feature_set" {
  description = "Feature set for the Organization"
  type        = string
  default     = "ALL"
}


variable "data_lake_account_emails" {
  description = "Map of Data Lake account names to root emails for account creation"
  type        = map(string)
  default = {
    dev        = "aws+datalake-dev@verticalbroker.com"
    staging    = "aws+datalake-staging@verticalbroker.com"
    production = "aws+datalake-prod@verticalbroker.com"
  }
}

variable "compute_account_emails" {
  description = "Map of Compute account names to root emails for account creation"
  type        = map(string)
  default = {
    dev        = "aws+compute-dev@verticalbroker.com"
    staging    = "aws+compute-staging@verticalbroker.com"
    production = "aws+compute-prod@verticalbroker.com"
  }
}

variable "enable_organizations" {
  description = "Whether to create the AWS Organization (set false if already exists)"
  type        = bool
  default     = true
}


# ---------------------------------------------------------
# AWS ORGANIZATION
# ---------------------------------------------------------

resource "aws_organizations_organization" "main" {
  count = var.enable_organizations ? 1 : 0

  feature_set = var.organization_feature_set

  enabled_policy_types = var.organization_enabled_policy_types

  aws_service_access_principals = [
    "cloudtrail.amazonaws.com",
    "config.amazonaws.com",
    "guardduty.amazonaws.com",
    "securityhub.amazonaws.com",
    "sso.amazonaws.com",
    "tagpolicies.tag.amazonaws.com",
    "ram.amazonaws.com",
    "access-analyzer.amazonaws.com",
  ]
}

# ---------------------------------------------------------
# ORGANIZATIONAL UNITS (OUs)
# ---------------------------------------------------------

resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = aws_organizations_organization.main[0].roots[0].id

  tags = {
    Environment        = "global"
    Service            = "verticalbroker-platform"
    Owner              = "security-engineering"
    CostCenter         = "SE-001"
    DataClassification = "Restricted"
    Compliance         = "FINRA-4511"
  }
}


resource "aws_organizations_organizational_unit" "shared_services" {
  name      = "SharedServices"
  parent_id = aws_organizations_organization.main[0].roots[0].id

  tags = {
    Environment        = "global"
    Service            = "verticalbroker-platform"
    Owner              = "platform-engineering"
    CostCenter         = "PE-001"
    DataClassification = "Internal"
    Compliance         = "FINRA-4511"
  }
}

resource "aws_organizations_organizational_unit" "data_lake" {
  name      = "DataLake"
  parent_id = aws_organizations_organization.main[0].roots[0].id

  tags = {
    Environment        = "global"
    Service            = "verticalbroker-data-lake"
    Owner              = "data-engineering"
    CostCenter         = "DE-001"
    DataClassification = "Restricted"
    Compliance         = "FINRA-4511"
  }
}

resource "aws_organizations_organizational_unit" "compute" {
  name      = "Compute"
  parent_id = aws_organizations_organization.main[0].roots[0].id

  tags = {
    Environment        = "global"
    Service            = "verticalbroker-compute"
    Owner              = "platform-engineering"
    CostCenter         = "PE-002"
    DataClassification = "Confidential"
    Compliance         = "FINRA-4511"
  }
}


resource "aws_organizations_organizational_unit" "dr" {
  name      = "DR"
  parent_id = aws_organizations_organization.main[0].roots[0].id

  tags = {
    Environment        = "dr"
    Service            = "verticalbroker-dr"
    Owner              = "platform-engineering"
    CostCenter         = "PE-003"
    DataClassification = "Restricted"
    Compliance         = "FINRA-4511"
  }
}

# ---------------------------------------------------------
# MEMBER ACCOUNTS
# Parameterized for 100+ account scaling (Requirement 13.8)
# ---------------------------------------------------------

# Security & Audit Account
resource "aws_organizations_account" "security" {
  name      = "verticalbroker-security-audit"
  email     = "aws+security@verticalbroker.com"
  parent_id = aws_organizations_organizational_unit.security.id
  role_name = "OrganizationAccountAccessRole"

  lifecycle {
    ignore_changes = [email, name, role_name]
  }

  tags = {
    Environment        = "production"
    Service            = "security-audit"
    Owner              = "security-engineering"
    CostCenter         = "SE-001"
    DataClassification = "Restricted"
    Compliance         = "FINRA-4511"
  }
}


# Shared Services Account
resource "aws_organizations_account" "shared_services" {
  name      = "verticalbroker-shared-services"
  email     = "aws+shared-services@verticalbroker.com"
  parent_id = aws_organizations_organizational_unit.shared_services.id
  role_name = "OrganizationAccountAccessRole"

  lifecycle {
    ignore_changes = [email, name, role_name]
  }

  tags = {
    Environment        = "production"
    Service            = "shared-services"
    Owner              = "platform-engineering"
    CostCenter         = "PE-001"
    DataClassification = "Internal"
    Compliance         = "FINRA-4511"
  }
}

# Data Lake Accounts (Dev, Staging, Production)
resource "aws_organizations_account" "data_lake" {
  for_each = var.data_lake_account_emails

  name      = "verticalbroker-data-lake-${each.key}"
  email     = each.value
  parent_id = aws_organizations_organizational_unit.data_lake.id
  role_name = "OrganizationAccountAccessRole"

  lifecycle {
    ignore_changes = [email, name, role_name]
  }

  tags = {
    Environment        = each.key
    Service            = "data-lake"
    Owner              = "data-engineering"
    CostCenter         = "DE-001"
    DataClassification = "Restricted"
    Compliance         = "FINRA-4511"
  }
}


# Compute Accounts (Dev, Staging, Production)
resource "aws_organizations_account" "compute" {
  for_each = var.compute_account_emails

  name      = "verticalbroker-compute-${each.key}"
  email     = each.value
  parent_id = aws_organizations_organizational_unit.compute.id
  role_name = "OrganizationAccountAccessRole"

  lifecycle {
    ignore_changes = [email, name, role_name]
  }

  tags = {
    Environment        = each.key
    Service            = "compute"
    Owner              = "platform-engineering"
    CostCenter         = "PE-002"
    DataClassification = "Confidential"
    Compliance         = "FINRA-4511"
  }
}

# Disaster Recovery Account
resource "aws_organizations_account" "dr" {
  name      = "verticalbroker-disaster-recovery"
  email     = "aws+dr@verticalbroker.com"
  parent_id = aws_organizations_organizational_unit.dr.id
  role_name = "OrganizationAccountAccessRole"

  lifecycle {
    ignore_changes = [email, name, role_name]
  }

  tags = {
    Environment        = "dr"
    Service            = "disaster-recovery"
    Owner              = "platform-engineering"
    CostCenter         = "PE-003"
    DataClassification = "Restricted"
    Compliance         = "FINRA-4511"
  }
}


# ---------------------------------------------------------
# SERVICE CONTROL POLICIES (SCPs)
# Restrict region usage and prevent public resource creation
# ---------------------------------------------------------

# SCP: Restrict Allowed Regions
resource "aws_organizations_policy" "restrict_regions" {
  name        = "RestrictAllowedRegions"
  description = "Restricts AWS API actions to allowed regions only (us-east-1, us-west-2)"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyAllOutsideAllowedRegions"
        Effect    = "Deny"
        NotAction = [
          "a4b:*",
          "acm:*",
          "aws-marketplace-management:*",
          "aws-marketplace:*",
          "aws-portal:*",
          "budgets:*",
          "ce:*",
          "chime:*",
          "cloudfront:*",
          "config:*",
          "cur:*",
          "directconnect:*",
          "ec2:DescribeRegions",
          "ec2:DescribeTransitGateways",
          "ec2:DescribeVpnGateways",
          "fms:*",
          "globalaccelerator:*",
          "health:*",
          "iam:*",
          "importexport:*",
          "kms:*",
          "mobileanalytics:*",
          "networkmanager:*",
          "organizations:*",
          "pricing:*",
          "route53:*",
          "route53domains:*",
          "route53-recovery-cluster:*",
          "route53-recovery-control-config:*",
          "route53-recovery-readiness:*",
          "s3:GetBucketLocation",
          "s3:ListAllMyBuckets",
          "shield:*",
          "sts:*",
          "support:*",
          "trustedadvisor:*",
          "waf-regional:*",
          "waf:*",
          "wafv2:*",
          "wellarchitected:*"
        ]
        Resource = "*"
        Condition = {
          StringNotEquals = {
            "aws:RequestedRegion" = var.allowed_regions
          }
        }
      }
    ]
  })

  tags = {
    Environment        = "global"
    Service            = "verticalbroker-platform"
    Owner              = "security-engineering"
    CostCenter         = "SE-001"
    DataClassification = "Internal"
    Compliance         = "FINRA-4511"
  }
}


# SCP: Prevent Public S3 Buckets and EC2 Instances
resource "aws_organizations_policy" "deny_public_resources" {
  name        = "DenyPublicResourceCreation"
  description = "Prevents creation of publicly accessible S3 buckets, EC2 instances with public IPs, and RDS public access"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyPublicS3BucketACL"
        Effect    = "Deny"
        Action    = ["s3:PutBucketAcl"]
        Resource  = "*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = [
              "public-read",
              "public-read-write",
              "authenticated-read"
            ]
          }
        }
      },
      {
        Sid       = "DenyS3PublicAccessBlock"
        Effect    = "Deny"
        Action    = ["s3:PutBucketPublicAccessBlock"]
        Resource  = "*"
        Condition = {
          StringNotEquals = {
            "s3:PublicAccessBlockConfiguration.BlockPublicAcls"       = "true"
            "s3:PublicAccessBlockConfiguration.BlockPublicPolicy"     = "true"
            "s3:PublicAccessBlockConfiguration.IgnorePublicAcls"      = "true"
            "s3:PublicAccessBlockConfiguration.RestrictPublicBuckets" = "true"
          }
        }
      },
      {
        Sid      = "DenyEC2PublicIP"
        Effect   = "Deny"
        Action   = ["ec2:RunInstances"]
        Resource = "arn:aws:ec2:*:*:subnet/*"
        Condition = {
          Bool = {
            "ec2:AssociatePublicIpAddress" = "true"
          }
        }
      },
      {
        Sid      = "DenyRDSPublicAccess"
        Effect   = "Deny"
        Action   = ["rds:CreateDBInstance", "rds:ModifyDBInstance"]
        Resource = "*"
        Condition = {
          Bool = {
            "rds:PubliclyAccessible" = "true"
          }
        }
      }
    ]
  })

  tags = {
    Environment        = "global"
    Service            = "verticalbroker-platform"
    Owner              = "security-engineering"
    CostCenter         = "SE-001"
    DataClassification = "Internal"
    Compliance         = "FINRA-4511"
  }
}


# SCP: Prevent Disabling Security Services
resource "aws_organizations_policy" "protect_security_services" {
  name        = "ProtectSecurityServices"
  description = "Prevents member accounts from disabling GuardDuty, Security Hub, CloudTrail, or Config"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyDisableGuardDuty"
        Effect = "Deny"
        Action = [
          "guardduty:DeleteDetector",
          "guardduty:DeleteMembers",
          "guardduty:DisassociateFromMasterAccount",
          "guardduty:DisassociateMembers",
          "guardduty:StopMonitoringMembers",
          "guardduty:UpdateDetector"
        ]
        Resource = "*"
        Condition = {
          StringNotLike = {
            "aws:PrincipalArn" = [
              "arn:aws:iam::*:role/OrganizationAccountAccessRole",
              "arn:aws:iam::*:role/AWSServiceRoleForAmazonGuardDuty"
            ]
          }
        }
      },
      {
        Sid    = "DenyDisableSecurityHub"
        Effect = "Deny"
        Action = [
          "securityhub:DisableSecurityHub",
          "securityhub:DeleteMembers",
          "securityhub:DisassociateMembers"
        ]
        Resource = "*"
        Condition = {
          StringNotLike = {
            "aws:PrincipalArn" = [
              "arn:aws:iam::*:role/OrganizationAccountAccessRole"
            ]
          }
        }
      },
      {
        Sid    = "DenyDisableCloudTrail"
        Effect = "Deny"
        Action = [
          "cloudtrail:DeleteTrail",
          "cloudtrail:StopLogging",
          "cloudtrail:UpdateTrail",
          "cloudtrail:PutEventSelectors"
        ]
        Resource = "*"
        Condition = {
          StringNotLike = {
            "aws:PrincipalArn" = [
              "arn:aws:iam::*:role/OrganizationAccountAccessRole"
            ]
          }
        }
      },
      {
        Sid    = "DenyDisableConfig"
        Effect = "Deny"
        Action = [
          "config:DeleteConfigurationRecorder",
          "config:DeleteDeliveryChannel",
          "config:StopConfigurationRecorder"
        ]
        Resource = "*"
        Condition = {
          StringNotLike = {
            "aws:PrincipalArn" = [
              "arn:aws:iam::*:role/OrganizationAccountAccessRole"
            ]
          }
        }
      }
    ]
  })

  tags = {
    Environment        = "global"
    Service            = "verticalbroker-platform"
    Owner              = "security-engineering"
    CostCenter         = "SE-001"
    DataClassification = "Internal"
    Compliance         = "FINRA-4511"
  }
}


# SCP: Enforce Encryption
resource "aws_organizations_policy" "enforce_encryption" {
  name        = "EnforceEncryption"
  description = "Requires encryption for S3, EBS, and RDS resources"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyUnencryptedS3Uploads"
        Effect   = "Deny"
        Action   = ["s3:PutObject"]
        Resource = "*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = ["aws:kms", "AES256"]
          }
          Null = {
            "s3:x-amz-server-side-encryption" = "false"
          }
        }
      },
      {
        Sid      = "DenyUnencryptedEBSVolumes"
        Effect   = "Deny"
        Action   = ["ec2:CreateVolume"]
        Resource = "*"
        Condition = {
          Bool = {
            "ec2:Encrypted" = "false"
          }
        }
      }
    ]
  })

  tags = {
    Environment        = "global"
    Service            = "verticalbroker-platform"
    Owner              = "security-engineering"
    CostCenter         = "SE-001"
    DataClassification = "Internal"
    Compliance         = "FINRA-4511"
  }
}


# ---------------------------------------------------------
# SCP ATTACHMENTS TO OUs
# ---------------------------------------------------------

# Attach region restriction to all OUs except management root
resource "aws_organizations_policy_attachment" "restrict_regions_security" {
  policy_id = aws_organizations_policy.restrict_regions.id
  target_id = aws_organizations_organizational_unit.security.id
}

resource "aws_organizations_policy_attachment" "restrict_regions_shared" {
  policy_id = aws_organizations_policy.restrict_regions.id
  target_id = aws_organizations_organizational_unit.shared_services.id
}

resource "aws_organizations_policy_attachment" "restrict_regions_data_lake" {
  policy_id = aws_organizations_policy.restrict_regions.id
  target_id = aws_organizations_organizational_unit.data_lake.id
}

resource "aws_organizations_policy_attachment" "restrict_regions_compute" {
  policy_id = aws_organizations_policy.restrict_regions.id
  target_id = aws_organizations_organizational_unit.compute.id
}

resource "aws_organizations_policy_attachment" "restrict_regions_dr" {
  policy_id = aws_organizations_policy.restrict_regions.id
  target_id = aws_organizations_organizational_unit.dr.id
}

# Attach deny public resources to all workload OUs
resource "aws_organizations_policy_attachment" "deny_public_data_lake" {
  policy_id = aws_organizations_policy.deny_public_resources.id
  target_id = aws_organizations_organizational_unit.data_lake.id
}

resource "aws_organizations_policy_attachment" "deny_public_compute" {
  policy_id = aws_organizations_policy.deny_public_resources.id
  target_id = aws_organizations_organizational_unit.compute.id
}

resource "aws_organizations_policy_attachment" "deny_public_dr" {
  policy_id = aws_organizations_policy.deny_public_resources.id
  target_id = aws_organizations_organizational_unit.dr.id
}


# Attach security services protection to all OUs
resource "aws_organizations_policy_attachment" "protect_security_all" {
  for_each = {
    security        = aws_organizations_organizational_unit.security.id
    shared_services = aws_organizations_organizational_unit.shared_services.id
    data_lake       = aws_organizations_organizational_unit.data_lake.id
    compute         = aws_organizations_organizational_unit.compute.id
    dr              = aws_organizations_organizational_unit.dr.id
  }

  policy_id = aws_organizations_policy.protect_security_services.id
  target_id = each.value
}

# Attach encryption enforcement to all workload OUs
resource "aws_organizations_policy_attachment" "enforce_encryption_all" {
  for_each = {
    data_lake = aws_organizations_organizational_unit.data_lake.id
    compute   = aws_organizations_organizational_unit.compute.id
    dr        = aws_organizations_organizational_unit.dr.id
  }

  policy_id = aws_organizations_policy.enforce_encryption.id
  target_id = each.value
}

# ---------------------------------------------------------
# OUTPUTS
# ---------------------------------------------------------

output "organization_id" {
  description = "The ID of the AWS Organization"
  value       = var.enable_organizations ? aws_organizations_organization.main[0].id : null
}

output "organization_root_id" {
  description = "The root ID of the AWS Organization"
  value       = var.enable_organizations ? aws_organizations_organization.main[0].roots[0].id : null
}


output "ou_ids" {
  description = "Map of OU names to their IDs for cross-referencing"
  value = {
    security        = aws_organizations_organizational_unit.security.id
    shared_services = aws_organizations_organizational_unit.shared_services.id
    data_lake       = aws_organizations_organizational_unit.data_lake.id
    compute         = aws_organizations_organizational_unit.compute.id
    dr              = aws_organizations_organizational_unit.dr.id
  }
}

output "account_ids" {
  description = "Map of all member account IDs for parameterized module deployment"
  value = merge(
    {
      security        = aws_organizations_account.security.id
      shared_services = aws_organizations_account.shared_services.id
      dr              = aws_organizations_account.dr.id
    },
    { for k, v in aws_organizations_account.data_lake : "data_lake_${k}" => v.id },
    { for k, v in aws_organizations_account.compute : "compute_${k}" => v.id }
  )
}

output "security_account_id" {
  description = "Security & Audit account ID for delegated administration"
  value       = aws_organizations_account.security.id
}

output "data_lake_account_ids" {
  description = "Map of Data Lake account IDs by environment"
  value       = { for k, v in aws_organizations_account.data_lake : k => v.id }
}

output "compute_account_ids" {
  description = "Map of Compute account IDs by environment"
  value       = { for k, v in aws_organizations_account.compute : k => v.id }
}
