# Security Module Provider Requirements
# VerticalBroker AWS Data Engineering Platform
#
# This module requires both the default AWS provider and a DR-region provider alias
# for cross-region KMS key replication.

terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.0"
      configuration_aliases = [aws.dr]
    }
  }
}
