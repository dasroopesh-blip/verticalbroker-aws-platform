# TFLint Configuration
# Requirement 13.7: terraform validate and tflint with zero errors

config {
  # Enable module inspection
  module = true
}

# AWS-specific rules
plugin "aws" {
  enabled = true
  version = "0.27.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Enforce naming conventions
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Require descriptions for all variables and outputs
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

# Prevent deprecated syntax
rule "terraform_deprecated_interpolation" {
  enabled = true
}

# Ensure all variables have type constraints
rule "terraform_typed_variables" {
  enabled = true
}

# Standard file naming
rule "terraform_standard_module_structure" {
  enabled = true
}
