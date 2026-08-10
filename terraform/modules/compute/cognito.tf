# Cognito Configuration - User Pool, JWT Authorizer, and Identity Pool
# VerticalBroker AWS Data Engineering Platform
#
# Implements:
# - Cognito User Pool for platform authentication
# - User Pool Client for API access with JWT tokens
# - Identity Pool for federated AWS credentials
# - Custom attributes for FINRA-regulated brokerage users
# - MFA enforcement and password policies
# - Token validity and refresh configuration
#
# Requirements: 8.2, 14.3
# - 8.2: Authenticate all requests using Cognito JWT tokens
# - 14.3: Role-based access control with least-privilege principles

# -----------------------------------------------------------------------------
# COGNITO USER POOL - Platform Identity Service
# Requirement 8.2: Cognito User Pool for JWT token validation
# -----------------------------------------------------------------------------

resource "aws_cognito_user_pool" "platform" {
  name = "${var.project_prefix}-platform-users-${var.environment}"

  # Account recovery via verified email
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Admin create user configuration
  admin_create_user_config {
    allow_admin_create_user_only = var.admin_create_user_only
  }


  # Username configuration
  username_configuration {
    case_sensitive = false
  }

  # Auto-verified attributes
  auto_verified_attributes = ["email"]

  # Email configuration
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  # MFA configuration - enforce for financial services compliance
  mfa_configuration = "ON"

  software_token_mfa_configuration {
    enabled = true
  }

  # Password policy - strong passwords for FINRA compliance
  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 1
  }

  # Schema: standard attributes
  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 5
      max_length = 256
    }
  }


  # Schema: custom attributes for brokerage platform
  schema {
    name                = "client_id"
    attribute_data_type = "String"
    required            = false
    mutable             = true

    string_attribute_constraints {
      min_length = 1
      max_length = 64
    }
  }

  schema {
    name                = "account_type"
    attribute_data_type = "String"
    required            = false
    mutable             = true

    string_attribute_constraints {
      min_length = 1
      max_length = 32
    }
  }

  schema {
    name                = "service_tier"
    attribute_data_type = "String"
    required            = false
    mutable             = true

    string_attribute_constraints {
      min_length = 1
      max_length = 32
    }
  }

  schema {
    name                = "risk_profile"
    attribute_data_type = "String"
    required            = false
    mutable             = true

    string_attribute_constraints {
      min_length = 1
      max_length = 32
    }
  }

  # User pool add-ons for advanced security
  user_pool_add_ons {
    advanced_security_mode = "ENFORCED"
  }

  tags = merge(var.mandatory_tags, {
    Service            = "cognito"
    DataClassification = "Restricted"
  })
}


# -----------------------------------------------------------------------------
# COGNITO USER POOL CLIENT - API Access
# JWT token generation for API Gateway authentication
# -----------------------------------------------------------------------------

resource "aws_cognito_user_pool_client" "platform_client" {
  name         = "${var.project_prefix}-api-client-${var.environment}"
  user_pool_id = aws_cognito_user_pool.platform.id

  # OAuth 2.0 configuration
  allowed_oauth_flows                  = ["code", "implicit"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes = [
    "email",
    "openid",
    "profile",
    "aws.cognito.signin.user.admin"
  ]

  # Supported identity providers
  supported_identity_providers = ["COGNITO"]

  # Callback URLs (platform frontend)
  callback_urls = var.cognito_callback_urls
  logout_urls   = var.cognito_logout_urls

  # Token validity configuration
  access_token_validity  = 1   # 1 hour
  id_token_validity      = 1   # 1 hour
  refresh_token_validity = 30  # 30 days

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # Security settings
  explicit_auth_flows = [
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_CUSTOM_AUTH"
  ]

  # Prevent client secret for public client (SPA)
  generate_secret = false

  # Read/write attributes
  read_attributes = [
    "email",
    "email_verified",
    "custom:client_id",
    "custom:account_type",
    "custom:service_tier",
    "custom:risk_profile"
  ]

  write_attributes = [
    "email",
    "custom:client_id",
    "custom:account_type",
    "custom:service_tier",
    "custom:risk_profile"
  ]
}


# -----------------------------------------------------------------------------
# COGNITO USER POOL CLIENT - Machine-to-Machine (M2M)
# For backend service authentication (server-side clients)
# -----------------------------------------------------------------------------

resource "aws_cognito_user_pool_client" "m2m_client" {
  name         = "${var.project_prefix}-m2m-client-${var.environment}"
  user_pool_id = aws_cognito_user_pool.platform.id

  # Client credentials flow for service-to-service auth
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = aws_cognito_resource_server.platform_api.scope_identifiers

  supported_identity_providers = ["COGNITO"]

  # M2M clients use client secrets
  generate_secret = true

  # Token validity for service accounts
  access_token_validity = 1 # 1 hour

  token_validity_units {
    access_token = "hours"
  }

  explicit_auth_flows = [
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]
}

# -----------------------------------------------------------------------------
# COGNITO RESOURCE SERVER - API Scopes
# Defines custom OAuth 2.0 scopes for fine-grained access control
# -----------------------------------------------------------------------------

resource "aws_cognito_resource_server" "platform_api" {
  identifier   = "https://api.${var.project_prefix}.com"
  name         = "${var.project_prefix}-platform-api"
  user_pool_id = aws_cognito_user_pool.platform.id

  scope {
    scope_name        = "orders.write"
    scope_description = "Submit and modify trade orders"
  }

  scope {
    scope_name        = "orders.read"
    scope_description = "Read order status and history"
  }

  scope {
    scope_name        = "portfolio.read"
    scope_description = "Read portfolio positions and balances"
  }

  scope {
    scope_name        = "advisory.read"
    scope_description = "Request advisory recommendations"
  }

  scope {
    scope_name        = "search.read"
    scope_description = "Execute search queries"
  }

  scope {
    scope_name        = "graph.read"
    scope_description = "Execute graph traversal queries"
  }

  scope {
    scope_name        = "query.execute"
    scope_description = "Execute Athena SQL queries"
  }

  scope {
    scope_name        = "marketdata.stream"
    scope_description = "Subscribe to real-time market data WebSocket"
  }
}


# -----------------------------------------------------------------------------
# COGNITO USER POOL GROUPS - RBAC
# Requirement 14.3: Role-based access control
# -----------------------------------------------------------------------------

resource "aws_cognito_user_group" "full_service_clients" {
  name         = "full-service-clients"
  user_pool_id = aws_cognito_user_pool.platform.id
  description  = "Full-Service clients with professional advisor access"
  precedence   = 10
  role_arn     = var.cognito_full_service_role_arn
}

resource "aws_cognito_user_group" "self_service_clients" {
  name         = "self-service-clients"
  user_pool_id = aws_cognito_user_pool.platform.id
  description  = "Self-Service online trading clients"
  precedence   = 20
  role_arn     = var.cognito_self_service_role_arn
}

resource "aws_cognito_user_group" "automated_service_clients" {
  name         = "automated-service-clients"
  user_pool_id = aws_cognito_user_pool.platform.id
  description  = "Automated-Service clients using RL digital advisor"
  precedence   = 30
  role_arn     = var.cognito_automated_service_role_arn
}

resource "aws_cognito_user_group" "platform_admins" {
  name         = "platform-admins"
  user_pool_id = aws_cognito_user_pool.platform.id
  description  = "Platform administrators with full access"
  precedence   = 1
  role_arn     = var.cognito_admin_role_arn
}

resource "aws_cognito_user_group" "compliance_analysts" {
  name         = "compliance-analysts"
  user_pool_id = aws_cognito_user_pool.platform.id
  description  = "Compliance team with audit and graph query access"
  precedence   = 5
  role_arn     = var.cognito_compliance_role_arn
}


# -----------------------------------------------------------------------------
# COGNITO IDENTITY POOL - Federated AWS Credentials
# Provides temporary AWS credentials to authenticated users
# -----------------------------------------------------------------------------

resource "aws_cognito_identity_pool" "platform" {
  identity_pool_name               = "${var.project_prefix}-platform-${var.environment}"
  allow_unauthenticated_identities = false
  allow_classic_flow               = false

  cognito_identity_providers {
    client_id               = aws_cognito_user_pool_client.platform_client.id
    provider_name           = aws_cognito_user_pool.platform.endpoint
    server_side_token_check = true
  }

  tags = merge(var.mandatory_tags, {
    Service            = "cognito-identity"
    DataClassification = "Restricted"
  })
}

# IAM roles for authenticated/unauthenticated identity pool users
resource "aws_cognito_identity_pool_roles_attachment" "platform" {
  identity_pool_id = aws_cognito_identity_pool.platform.id

  roles = {
    "authenticated" = var.cognito_authenticated_role_arn
  }

  role_mapping {
    identity_provider         = "${aws_cognito_user_pool.platform.endpoint}:${aws_cognito_user_pool_client.platform_client.id}"
    ambiguous_role_resolution = "AuthenticatedRole"
    type                      = "Token"
  }
}


# -----------------------------------------------------------------------------
# COGNITO USER POOL DOMAIN - Token endpoint
# -----------------------------------------------------------------------------

resource "aws_cognito_user_pool_domain" "platform" {
  domain       = "${var.project_prefix}-${var.environment}"
  user_pool_id = aws_cognito_user_pool.platform.id
}

# -----------------------------------------------------------------------------
# COGNITO VARIABLES
# -----------------------------------------------------------------------------

variable "admin_create_user_only" {
  description = "Restrict user registration to admin-only creation"
  type        = bool
  default     = true
}

variable "cognito_callback_urls" {
  description = "Allowed OAuth callback URLs for the user pool client"
  type        = list(string)
  default     = ["https://app.verticalbroker.com/callback"]
}

variable "cognito_logout_urls" {
  description = "Allowed logout URLs for the user pool client"
  type        = list(string)
  default     = ["https://app.verticalbroker.com/logout"]
}

variable "cognito_full_service_role_arn" {
  description = "IAM role ARN for Full-Service client group"
  type        = string
  default     = ""
}

variable "cognito_self_service_role_arn" {
  description = "IAM role ARN for Self-Service client group"
  type        = string
  default     = ""
}

variable "cognito_automated_service_role_arn" {
  description = "IAM role ARN for Automated-Service client group"
  type        = string
  default     = ""
}

variable "cognito_admin_role_arn" {
  description = "IAM role ARN for Platform Admin group"
  type        = string
  default     = ""
}

variable "cognito_compliance_role_arn" {
  description = "IAM role ARN for Compliance Analyst group"
  type        = string
  default     = ""
}


variable "cognito_authenticated_role_arn" {
  description = "IAM role ARN for authenticated identity pool users"
  type        = string
}

# -----------------------------------------------------------------------------
# COGNITO OUTPUTS
# -----------------------------------------------------------------------------

output "user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.platform.id
}

output "user_pool_arn" {
  description = "Cognito User Pool ARN"
  value       = aws_cognito_user_pool.platform.arn
}

output "user_pool_endpoint" {
  description = "Cognito User Pool endpoint (issuer URL)"
  value       = aws_cognito_user_pool.platform.endpoint
}

output "user_pool_client_id" {
  description = "Cognito User Pool Client ID (audience)"
  value       = aws_cognito_user_pool_client.platform_client.id
}

output "m2m_client_id" {
  description = "Cognito M2M Client ID for service-to-service auth"
  value       = aws_cognito_user_pool_client.m2m_client.id
}

output "identity_pool_id" {
  description = "Cognito Identity Pool ID"
  value       = aws_cognito_identity_pool.platform.id
}

output "user_pool_domain" {
  description = "Cognito User Pool domain for OAuth endpoints"
  value       = aws_cognito_user_pool_domain.platform.domain
}

output "resource_server_identifier" {
  description = "Resource server identifier for OAuth scopes"
  value       = aws_cognito_resource_server.platform_api.identifier
}

output "resource_server_scopes" {
  description = "List of OAuth scope identifiers"
  value       = aws_cognito_resource_server.platform_api.scope_identifiers
}
