# Root Terragrunt Configuration
# Provides DRY configuration management across all environments
# Requirements: 13.1, 13.2, 13.3, 13.5

# ---------------------------------------------------------
# REMOTE STATE CONFIGURATION
# S3 backend with DynamoDB locking, encryption, and versioning
# Requirement 13.3: State in S3 with DynamoDB locking, state encryption,
# and cross-account access policies for the CI/CD pipeline service role
# ---------------------------------------------------------
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = "verticalbroker-terraform-state-${local.environment}"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.aws_region
    encrypt        = true
    kms_key_id     = "alias/terraform-state-key"
    dynamodb_table = "verticalbroker-terraform-locks-${local.environment}"

    # Enable bucket versioning for state rollback
    s3_bucket_tags = {
      Environment        = local.environment
      Service            = "terraform-state"
      Owner              = "platform-engineering"
      CostCenter         = "DE-001"
      DataClassification = "Restricted"
      Compliance         = "FINRA-4511"
    }

    dynamodb_table_tags = {
      Environment        = local.environment
      Service            = "terraform-locks"
      Owner              = "platform-engineering"
      CostCenter         = "DE-001"
      DataClassification = "Restricted"
      Compliance         = "FINRA-4511"
    }
  }
}

# ---------------------------------------------------------
# GENERATE PROVIDER CONFIGURATION
# Terraform 1.5+ with AWS Provider 5.x
# ---------------------------------------------------------
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "${local.aws_region}"

  # Cross-account assume role for multi-account deployment
  # Requirement 13.8: Parameterized by account ID and OU for 100+ accounts
  assume_role {
    role_arn = "arn:aws:iam::${local.aws_account_id}:role/TerraformDeploymentRole"
  }

  # Mandatory tags applied to all resources (Requirement 13.5)
  default_tags {
    tags = {
      Environment        = "${local.environment}"
      Service            = "verticalbroker-platform"
      Owner              = "data-engineering"
      CostCenter         = "DE-001"
      DataClassification = "${local.data_classification}"
      Compliance         = "FINRA-4511"
      ManagedBy          = "terraform"
    }
  }
}

# Secondary provider for DR cross-region resources
provider "aws" {
  alias  = "dr"
  region = "${local.dr_region}"

  assume_role {
    role_arn = "arn:aws:iam::${local.aws_account_id}:role/TerraformDeploymentRole"
  }

  default_tags {
    tags = {
      Environment        = "${local.environment}"
      Service            = "verticalbroker-platform"
      Owner              = "data-engineering"
      CostCenter         = "DE-001"
      DataClassification = "${local.data_classification}"
      Compliance         = "FINRA-4511"
      ManagedBy          = "terraform"
    }
  }
}
EOF
}

# ---------------------------------------------------------
# LOCAL VALUES
# Environment-specific variables resolved from directory path
# ---------------------------------------------------------
locals {
  # Parse environment from the directory path
  environment = basename(get_terragrunt_dir())

  # Environment-specific configuration
  env_config = read_terragrunt_config(find_in_parent_folders("env.hcl"))

  aws_region          = local.env_config.locals.aws_region
  aws_account_id      = local.env_config.locals.aws_account_id
  dr_region           = local.env_config.locals.dr_region
  data_classification = local.env_config.locals.data_classification
  organizational_unit = local.env_config.locals.organizational_unit
}

# ---------------------------------------------------------
# COMMON INPUTS
# Variables passed to all modules regardless of environment
# ---------------------------------------------------------
inputs = {
  environment          = local.environment
  aws_region           = local.aws_region
  aws_account_id       = local.aws_account_id
  organizational_unit  = local.organizational_unit
  dr_region            = local.dr_region
  data_classification  = local.data_classification

  # Platform-wide constants
  platform_name        = "verticalbroker"
  terraform_state_bucket = "verticalbroker-terraform-state-${local.environment}"

  # Mandatory tags (Requirement 13.5)
  mandatory_tags = {
    Environment        = local.environment
    Service            = "verticalbroker-platform"
    Owner              = "data-engineering"
    CostCenter         = "DE-001"
    DataClassification = local.data_classification
    Compliance         = "FINRA-4511"
    ManagedBy          = "terraform"
  }
}

# ---------------------------------------------------------
# TERRAFORM VERSION CONSTRAINT
# ---------------------------------------------------------
terraform_version_constraint = ">= 1.5.0"
