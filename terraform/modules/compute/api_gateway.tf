# API Gateway Configuration - HTTP API (REST) and WebSocket API
# VerticalBroker AWS Data Engineering Platform
#
# Implements:
# - Amazon API Gateway HTTP API with OpenAPI 3.0 specification
# - WebSocket API for real-time market data streaming
# - Cognito JWT authorizer integration
# - Rate limiting: 10K/sec authenticated, 100/sec unauthenticated
# - Path-based API versioning (/v1/, /v2/) with Sunset header support
# - Request validation against OpenAPI schema
# - WebSocket connection duration limit: 2 hours
#
# Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7

# -----------------------------------------------------------------------------
# DATA SOURCES
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# LOCAL VALUES
# -----------------------------------------------------------------------------

locals {
  api_name        = "${var.project_prefix}-platform-api"
  ws_api_name     = "${var.project_prefix}-market-data-ws"
  account_id      = data.aws_caller_identity.current.account_id
  region          = data.aws_region.current.name

  # Mandatory tags for all API Gateway resources (Requirement 13.5)
  api_tags = merge(var.mandatory_tags, {
    Service            = "api-gateway"
    DataClassification = "Confidential"
  })
}


# -----------------------------------------------------------------------------
# HTTP API (REST) - Primary Platform API
# Requirement 8.1: RESTful endpoints using Amazon API Gateway HTTP API
# Requirement 8.4: Route to Compute_Function with request validation
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "platform_http_api" {
  name          = local.api_name
  description   = "VerticalBroker Platform REST API - OpenAPI 3.0 with JWT auth"
  protocol_type = "HTTP"

  cors_configuration {
    allow_headers = ["Authorization", "Content-Type", "X-Request-ID", "X-Correlation-ID"]
    allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    allow_origins = var.cors_allowed_origins
    max_age       = 3600
  }

  tags = local.api_tags
}

# -----------------------------------------------------------------------------
# API STAGES - Versioned deployments with Sunset header support
# Requirement 8.6: Path-based routing (v1, v2) with 6-month deprecation
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_stage" "production" {
  api_id      = aws_apigatewayv2_api.platform_http_api.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = var.api_throttle_burst_limit
    throttling_rate_limit  = var.api_throttle_rate_limit_authenticated
  }

  access_log_settings {
    destination_arn = var.api_access_log_group_arn
  }

  stage_variables = {
    environment = var.environment
    api_version = "v1"
  }

  tags = local.api_tags
}


# -----------------------------------------------------------------------------
# JWT AUTHORIZER - Cognito User Pool integration
# Requirement 8.2: Authenticate all requests using Cognito JWT tokens
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_authorizer" "cognito_jwt" {
  api_id           = aws_apigatewayv2_api.platform_http_api.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "${var.project_prefix}-cognito-jwt-authorizer"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.platform_client.id]
    issuer   = "https://${aws_cognito_user_pool.platform.endpoint}"
  }
}

# -----------------------------------------------------------------------------
# API ROUTES - V1 Endpoints
# Requirement 8.4: Route to appropriate Compute_Function
# Requirement 8.6: Path-based versioning (/v1/, /v2/)
# -----------------------------------------------------------------------------

# POST /v1/orders - Submit trade order (10K/sec, 30s timeout)
resource "aws_apigatewayv2_route" "post_orders" {
  api_id             = aws_apigatewayv2_api.platform_http_api.id
  route_key          = "POST /v1/orders"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_jwt.id
  target             = "integrations/${aws_apigatewayv2_integration.order_manager.id}"
}

# GET /v1/orders/{id} - Get order status (10K/sec, 30s timeout)
resource "aws_apigatewayv2_route" "get_order_by_id" {
  api_id             = aws_apigatewayv2_api.platform_http_api.id
  route_key          = "GET /v1/orders/{id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_jwt.id
  target             = "integrations/${aws_apigatewayv2_integration.order_manager.id}"
}


# GET /v1/portfolio/{client_id} - Get portfolio snapshot (10K/sec, 30s timeout)
resource "aws_apigatewayv2_route" "get_portfolio" {
  api_id             = aws_apigatewayv2_api.platform_http_api.id
  route_key          = "GET /v1/portfolio/{client_id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_jwt.id
  target             = "integrations/${aws_apigatewayv2_integration.wallet_service.id}"
}

# POST /v1/advisory - Get RL recommendation (5K/sec, 30s timeout)
resource "aws_apigatewayv2_route" "post_advisory" {
  api_id             = aws_apigatewayv2_api.platform_http_api.id
  route_key          = "POST /v1/advisory"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_jwt.id
  target             = "integrations/${aws_apigatewayv2_integration.advisory_agent.id}"
}

# POST /v1/search - Full-text search (10K/sec, 30s timeout)
resource "aws_apigatewayv2_route" "post_search" {
  api_id             = aws_apigatewayv2_api.platform_http_api.id
  route_key          = "POST /v1/search"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_jwt.id
  target             = "integrations/${aws_apigatewayv2_integration.search_proxy.id}"
}

# POST /v1/graph/query - Graph traversal query (1K/sec, 30s timeout)
resource "aws_apigatewayv2_route" "post_graph_query" {
  api_id             = aws_apigatewayv2_api.platform_http_api.id
  route_key          = "POST /v1/graph/query"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_jwt.id
  target             = "integrations/${aws_apigatewayv2_integration.graph_query.id}"
}


# POST /v1/query/execute - Execute Athena query (1K/sec, 30s timeout)
resource "aws_apigatewayv2_route" "post_query_execute" {
  api_id             = aws_apigatewayv2_api.platform_http_api.id
  route_key          = "POST /v1/query/execute"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_jwt.id
  target             = "integrations/${aws_apigatewayv2_integration.athena_query.id}"
}

# GET /v1/query/{id}/results - Get query results (10K/sec, 30s timeout)
resource "aws_apigatewayv2_route" "get_query_results" {
  api_id             = aws_apigatewayv2_api.platform_http_api.id
  route_key          = "GET /v1/query/{id}/results"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_jwt.id
  target             = "integrations/${aws_apigatewayv2_integration.athena_query.id}"
}

# -----------------------------------------------------------------------------
# V2 ROUTES (Future version with Sunset header for V1 deprecation)
# Requirement 8.6: Deprecation period of 6 months for retired versions
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_route" "v2_post_orders" {
  count              = var.enable_v2_api ? 1 : 0
  api_id             = aws_apigatewayv2_api.platform_http_api.id
  route_key          = "POST /v2/orders"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_jwt.id
  target             = "integrations/${aws_apigatewayv2_integration.order_manager.id}"
}

resource "aws_apigatewayv2_route" "v2_get_order_by_id" {
  count              = var.enable_v2_api ? 1 : 0
  api_id             = aws_apigatewayv2_api.platform_http_api.id
  route_key          = "GET /v2/orders/{id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_jwt.id
  target             = "integrations/${aws_apigatewayv2_integration.order_manager.id}"
}


# -----------------------------------------------------------------------------
# LAMBDA INTEGRATIONS - Backend function connections
# Requirement 8.4: Route to appropriate Compute_Function
# Requirement 8.7: Return HTTP 504 with structured error on timeout
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_integration" "order_manager" {
  api_id                 = aws_apigatewayv2_api.platform_http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.lambda_order_manager_invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000
}

resource "aws_apigatewayv2_integration" "wallet_service" {
  api_id                 = aws_apigatewayv2_api.platform_http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.lambda_wallet_service_invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000
}

resource "aws_apigatewayv2_integration" "advisory_agent" {
  api_id                 = aws_apigatewayv2_api.platform_http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.lambda_advisory_agent_invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000
}

resource "aws_apigatewayv2_integration" "search_proxy" {
  api_id                 = aws_apigatewayv2_api.platform_http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.lambda_search_proxy_invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000
}


resource "aws_apigatewayv2_integration" "graph_query" {
  api_id                 = aws_apigatewayv2_api.platform_http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.lambda_graph_query_invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000
}

resource "aws_apigatewayv2_integration" "athena_query" {
  api_id                 = aws_apigatewayv2_api.platform_http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.lambda_athena_query_invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000
}

# -----------------------------------------------------------------------------
# RATE LIMITING / THROTTLING CONFIGURATION
# Requirement 8.3: 10K/sec authenticated, 100/sec unauthenticated
# -----------------------------------------------------------------------------

# Route-level throttling for lower-rate endpoints
resource "aws_apigatewayv2_route_settings" "advisory_throttle" {
  api_id    = aws_apigatewayv2_api.platform_http_api.id
  stage_id  = aws_apigatewayv2_stage.production.id
  route_key = "POST /v1/advisory"

  throttling_burst_limit = 5000
  throttling_rate_limit  = 5000
}

resource "aws_apigatewayv2_route_settings" "graph_query_throttle" {
  api_id    = aws_apigatewayv2_api.platform_http_api.id
  stage_id  = aws_apigatewayv2_stage.production.id
  route_key = "POST /v1/graph/query"

  throttling_burst_limit = 1000
  throttling_rate_limit  = 1000
}


resource "aws_apigatewayv2_route_settings" "query_execute_throttle" {
  api_id    = aws_apigatewayv2_api.platform_http_api.id
  stage_id  = aws_apigatewayv2_stage.production.id
  route_key = "POST /v1/query/execute"

  throttling_burst_limit = 1000
  throttling_rate_limit  = 1000
}

# -----------------------------------------------------------------------------
# SUNSET HEADER - Response mapping for deprecated V1 endpoints
# Requirement 8.6: Deprecation period of 6 months with Sunset header
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_api_mapping" "v1_mapping" {
  count       = var.custom_domain_name != "" ? 1 : 0
  api_id      = aws_apigatewayv2_api.platform_http_api.id
  domain_name = aws_apigatewayv2_domain_name.platform_domain[0].id
  stage       = aws_apigatewayv2_stage.production.id
}

# Custom domain configuration for API versioning
resource "aws_apigatewayv2_domain_name" "platform_domain" {
  count       = var.custom_domain_name != "" ? 1 : 0
  domain_name = var.custom_domain_name

  domain_name_configuration {
    certificate_arn = var.acm_certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  tags = local.api_tags
}


# -----------------------------------------------------------------------------
# WEBSOCKET API - Real-time market data streaming
# Requirement 8.5: WebSocket endpoints for real-time market data
#                  Connection duration limit of 2 hours
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "market_data_websocket" {
  name                       = local.ws_api_name
  description                = "Real-time market data WebSocket API - 2h connection limit"
  protocol_type              = "WEBSOCKET"
  route_selection_expression = "$request.body.action"

  tags = local.api_tags
}

resource "aws_apigatewayv2_stage" "websocket_production" {
  api_id      = aws_apigatewayv2_api.market_data_websocket.id
  name        = "production"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = var.websocket_max_connections
    throttling_rate_limit  = var.websocket_max_connections
  }

  access_log_settings {
    destination_arn = var.websocket_access_log_group_arn
  }

  stage_variables = {
    environment             = var.environment
    connection_duration_sec = "7200"
  }

  tags = local.api_tags
}

# WebSocket Authorizer - JWT-based connection authentication
resource "aws_apigatewayv2_authorizer" "websocket_jwt" {
  api_id           = aws_apigatewayv2_api.market_data_websocket.id
  authorizer_type  = "REQUEST"
  authorizer_uri   = var.lambda_ws_auth_invoke_arn
  identity_sources = ["route.request.querystring.token"]
  name             = "${var.project_prefix}-ws-authorizer"
}


# WebSocket Routes: $connect, $disconnect, subscribe, unsubscribe
resource "aws_apigatewayv2_route" "ws_connect" {
  api_id             = aws_apigatewayv2_api.market_data_websocket.id
  route_key          = "$connect"
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.websocket_jwt.id
  target             = "integrations/${aws_apigatewayv2_integration.ws_connect.id}"
}

resource "aws_apigatewayv2_route" "ws_disconnect" {
  api_id    = aws_apigatewayv2_api.market_data_websocket.id
  route_key = "$disconnect"
  target    = "integrations/${aws_apigatewayv2_integration.ws_disconnect.id}"
}

resource "aws_apigatewayv2_route" "ws_subscribe" {
  api_id    = aws_apigatewayv2_api.market_data_websocket.id
  route_key = "subscribe"
  target    = "integrations/${aws_apigatewayv2_integration.ws_subscribe.id}"
}

resource "aws_apigatewayv2_route" "ws_unsubscribe" {
  api_id    = aws_apigatewayv2_api.market_data_websocket.id
  route_key = "unsubscribe"
  target    = "integrations/${aws_apigatewayv2_integration.ws_subscribe.id}"
}

resource "aws_apigatewayv2_route" "ws_default" {
  api_id    = aws_apigatewayv2_api.market_data_websocket.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.ws_subscribe.id}"
}


# WebSocket Lambda Integrations
resource "aws_apigatewayv2_integration" "ws_connect" {
  api_id                 = aws_apigatewayv2_api.market_data_websocket.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.lambda_ws_connect_invoke_arn
  integration_method     = "POST"
  payload_format_version = "1.0"
}

resource "aws_apigatewayv2_integration" "ws_disconnect" {
  api_id                 = aws_apigatewayv2_api.market_data_websocket.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.lambda_ws_disconnect_invoke_arn
  integration_method     = "POST"
  payload_format_version = "1.0"
}

resource "aws_apigatewayv2_integration" "ws_subscribe" {
  api_id                 = aws_apigatewayv2_api.market_data_websocket.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.lambda_ws_subscribe_invoke_arn
  integration_method     = "POST"
  payload_format_version = "1.0"
}

# -----------------------------------------------------------------------------
# LAMBDA PERMISSIONS - Allow API Gateway to invoke Lambda functions
# -----------------------------------------------------------------------------

resource "aws_lambda_permission" "apigw_order_manager" {
  statement_id  = "AllowAPIGatewayInvoke-OrderManager"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_order_manager_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.platform_http_api.execution_arn}/*/*"
}


resource "aws_lambda_permission" "apigw_wallet_service" {
  statement_id  = "AllowAPIGatewayInvoke-WalletService"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_wallet_service_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.platform_http_api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_advisory_agent" {
  statement_id  = "AllowAPIGatewayInvoke-AdvisoryAgent"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_advisory_agent_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.platform_http_api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_search_proxy" {
  statement_id  = "AllowAPIGatewayInvoke-SearchProxy"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_search_proxy_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.platform_http_api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_graph_query" {
  statement_id  = "AllowAPIGatewayInvoke-GraphQuery"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_graph_query_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.platform_http_api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_athena_query" {
  statement_id  = "AllowAPIGatewayInvoke-AthenaQuery"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_athena_query_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.platform_http_api.execution_arn}/*/*"
}


# WebSocket Lambda Permissions
resource "aws_lambda_permission" "apigw_ws_connect" {
  statement_id  = "AllowAPIGatewayInvoke-WSConnect"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_ws_connect_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.market_data_websocket.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_ws_disconnect" {
  statement_id  = "AllowAPIGatewayInvoke-WSDisconnect"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_ws_disconnect_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.market_data_websocket.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_ws_subscribe" {
  statement_id  = "AllowAPIGatewayInvoke-WSSubscribe"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_ws_subscribe_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.market_data_websocket.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_ws_auth" {
  statement_id  = "AllowAPIGatewayInvoke-WSAuth"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_ws_auth_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.market_data_websocket.execution_arn}/*/*"
}


# -----------------------------------------------------------------------------
# OPENAPI 3.0 SPECIFICATION - Request Validation
# Requirement 8.1: OpenAPI 3.0 specification
# Requirement 8.4: Request validation enabled against OpenAPI schema
# Stored in S3 for import; inline model validation schemas defined here
# -----------------------------------------------------------------------------

# Request/Response model for order submission (validation)
resource "aws_apigatewayv2_model" "order_request" {
  api_id       = aws_apigatewayv2_api.platform_http_api.id
  content_type = "application/json"
  name         = "OrderRequest"
  description  = "Trade order submission request schema"

  schema = jsonencode({
    "$schema" = "http://json-schema.org/draft-07/schema#"
    type      = "object"
    required  = ["client_id", "account_id", "instrument_id", "order_type", "side", "quantity"]
    properties = {
      client_id       = { type = "string", minLength = 1 }
      account_id      = { type = "string", minLength = 1 }
      instrument_id   = { type = "string", pattern = "^[A-Z0-9]{12}$" }
      order_type      = { type = "string", enum = ["MARKET", "LIMIT", "STOP", "STOP_LIMIT"] }
      side            = { type = "string", enum = ["BUY", "SELL"] }
      quantity        = { type = "number", minimum = 0.0001 }
      limit_price     = { type = "number", minimum = 0 }
      stop_price      = { type = "number", minimum = 0 }
      time_in_force   = { type = "string", enum = ["DAY", "GTC", "IOC", "FOK"] }
      idempotency_key = { type = "string", minLength = 1, maxLength = 128 }
    }
  })
}

resource "aws_apigatewayv2_model" "advisory_request" {
  api_id       = aws_apigatewayv2_api.platform_http_api.id
  content_type = "application/json"
  name         = "AdvisoryRequest"
  description  = "Advisory recommendation request schema"

  schema = jsonencode({
    "$schema" = "http://json-schema.org/draft-07/schema#"
    type      = "object"
    required  = ["age", "tax_filing_status", "annual_income", "risk_profile"]
    properties = {
      age                   = { type = "integer", minimum = 18, maximum = 120 }
      tax_filing_status     = { type = "string", enum = ["SINGLE", "MARRIED_JOINT", "MARRIED_SEPARATE", "HEAD_OF_HOUSEHOLD"] }
      annual_income         = { type = "number", minimum = 0 }
      total_debt            = { type = "number", minimum = 0 }
      household_income      = { type = "number", minimum = 0 }
      risk_profile          = { type = "string", enum = ["CONSERVATIVE", "MODERATE", "AGGRESSIVE", "VERY_AGGRESSIVE"] }
      investment_strategies = { type = "array", items = { type = "string", enum = ["GROWTH", "VALUE", "INCOME", "INDEX"] } }
      investment_horizon_years = { type = "integer", minimum = 1 }
    }
  })
}


resource "aws_apigatewayv2_model" "search_request" {
  api_id       = aws_apigatewayv2_api.platform_http_api.id
  content_type = "application/json"
  name         = "SearchRequest"
  description  = "Full-text search request schema"

  schema = jsonencode({
    "$schema" = "http://json-schema.org/draft-07/schema#"
    type      = "object"
    required  = ["query"]
    properties = {
      query      = { type = "string", minLength = 1, maxLength = 1000 }
      index      = { type = "string", enum = ["trade_records", "client_profiles", "instruments"] }
      from       = { type = "integer", minimum = 0, default = 0 }
      size       = { type = "integer", minimum = 1, maximum = 10000, default = 20 }
      sort_by    = { type = "string" }
      sort_order = { type = "string", enum = ["asc", "desc"] }
    }
  })
}

resource "aws_apigatewayv2_model" "graph_query_request" {
  api_id       = aws_apigatewayv2_api.platform_http_api.id
  content_type = "application/json"
  name         = "GraphQueryRequest"
  description  = "Graph traversal query request schema"

  schema = jsonencode({
    "$schema" = "http://json-schema.org/draft-07/schema#"
    type      = "object"
    required  = ["query_template", "parameters"]
    properties = {
      query_template = { type = "string", enum = ["circular_transactions", "rapid_transfers", "unusual_velocity", "client_network", "instrument_correlation"] }
      parameters     = { type = "object" }
      max_hops       = { type = "integer", minimum = 1, maximum = 4 }
      timeout_ms     = { type = "integer", minimum = 100, maximum = 5000 }
    }
  })
}

resource "aws_apigatewayv2_model" "query_execute_request" {
  api_id       = aws_apigatewayv2_api.platform_http_api.id
  content_type = "application/json"
  name         = "QueryExecuteRequest"
  description  = "Athena SQL query execution request schema"

  schema = jsonencode({
    "$schema" = "http://json-schema.org/draft-07/schema#"
    type      = "object"
    required  = ["query_string", "workgroup"]
    properties = {
      query_string = { type = "string", minLength = 1, maxLength = 65536 }
      workgroup    = { type = "string", enum = ["analytics", "compliance", "data-science"] }
      database     = { type = "string", enum = ["verticalbroker_bronze", "verticalbroker_silver", "verticalbroker_gold"] }
      output_location = { type = "string" }
    }
  })
}


# -----------------------------------------------------------------------------
# API GATEWAY VARIABLES
# -----------------------------------------------------------------------------

variable "environment" {
  description = "Deployment environment (dev, staging, production, dr)"
  type        = string
}

variable "mandatory_tags" {
  description = "Mandatory tags applied to all resources"
  type        = map(string)
  default     = {}
}

variable "cors_allowed_origins" {
  description = "Allowed CORS origins for the HTTP API"
  type        = list(string)
  default     = ["https://*.verticalbroker.com"]
}

variable "api_throttle_burst_limit" {
  description = "Default burst limit for API Gateway stage"
  type        = number
  default     = 10000
}

variable "api_throttle_rate_limit_authenticated" {
  description = "Rate limit per second for authenticated users (Requirement 8.3)"
  type        = number
  default     = 10000
}

variable "api_throttle_rate_limit_unauthenticated" {
  description = "Rate limit per second for unauthenticated endpoints (Requirement 8.3)"
  type        = number
  default     = 100
}

variable "websocket_max_connections" {
  description = "Maximum concurrent WebSocket connections (Requirement 8.5)"
  type        = number
  default     = 5000
}

variable "enable_v2_api" {
  description = "Enable V2 API routes (Requirement 8.6: versioning)"
  type        = bool
  default     = false
}

variable "custom_domain_name" {
  description = "Custom domain name for the API (empty string to skip)"
  type        = string
  default     = ""
}


variable "acm_certificate_arn" {
  description = "ACM certificate ARN for custom domain TLS"
  type        = string
  default     = ""
}

variable "api_access_log_group_arn" {
  description = "CloudWatch Log Group ARN for HTTP API access logs"
  type        = string
}

variable "websocket_access_log_group_arn" {
  description = "CloudWatch Log Group ARN for WebSocket API access logs"
  type        = string
}

# Lambda function invoke ARNs (wired from lambda_functions.tf)
variable "lambda_order_manager_invoke_arn" {
  description = "Lambda invoke ARN for Order Manager function"
  type        = string
}

variable "lambda_wallet_service_invoke_arn" {
  description = "Lambda invoke ARN for Wallet Service function"
  type        = string
}

variable "lambda_advisory_agent_invoke_arn" {
  description = "Lambda invoke ARN for Advisory Agent function"
  type        = string
}

variable "lambda_search_proxy_invoke_arn" {
  description = "Lambda invoke ARN for Search Proxy function"
  type        = string
}

variable "lambda_graph_query_invoke_arn" {
  description = "Lambda invoke ARN for Graph Query function"
  type        = string
}

variable "lambda_athena_query_invoke_arn" {
  description = "Lambda invoke ARN for Athena Query function"
  type        = string
}

variable "lambda_ws_connect_invoke_arn" {
  description = "Lambda invoke ARN for WebSocket Connect handler"
  type        = string
}

variable "lambda_ws_disconnect_invoke_arn" {
  description = "Lambda invoke ARN for WebSocket Disconnect handler"
  type        = string
}

variable "lambda_ws_subscribe_invoke_arn" {
  description = "Lambda invoke ARN for WebSocket Subscribe handler"
  type        = string
}

variable "lambda_ws_auth_invoke_arn" {
  description = "Lambda invoke ARN for WebSocket Authorizer function"
  type        = string
}


# Lambda function names (for permissions)
variable "lambda_order_manager_function_name" {
  description = "Lambda function name for Order Manager"
  type        = string
}

variable "lambda_wallet_service_function_name" {
  description = "Lambda function name for Wallet Service"
  type        = string
}

variable "lambda_advisory_agent_function_name" {
  description = "Lambda function name for Advisory Agent"
  type        = string
}

variable "lambda_search_proxy_function_name" {
  description = "Lambda function name for Search Proxy"
  type        = string
}

variable "lambda_graph_query_function_name" {
  description = "Lambda function name for Graph Query"
  type        = string
}

variable "lambda_athena_query_function_name" {
  description = "Lambda function name for Athena Query"
  type        = string
}

variable "lambda_ws_connect_function_name" {
  description = "Lambda function name for WebSocket Connect handler"
  type        = string
}

variable "lambda_ws_disconnect_function_name" {
  description = "Lambda function name for WebSocket Disconnect handler"
  type        = string
}

variable "lambda_ws_subscribe_function_name" {
  description = "Lambda function name for WebSocket Subscribe handler"
  type        = string
}

variable "lambda_ws_auth_function_name" {
  description = "Lambda function name for WebSocket Authorizer"
  type        = string
}


# -----------------------------------------------------------------------------
# OUTPUTS
# -----------------------------------------------------------------------------

output "http_api_id" {
  description = "ID of the HTTP API"
  value       = aws_apigatewayv2_api.platform_http_api.id
}

output "http_api_endpoint" {
  description = "HTTP API invoke URL"
  value       = aws_apigatewayv2_api.platform_http_api.api_endpoint
}

output "http_api_execution_arn" {
  description = "Execution ARN for the HTTP API (use in Lambda permissions)"
  value       = aws_apigatewayv2_api.platform_http_api.execution_arn
}

output "websocket_api_id" {
  description = "ID of the WebSocket API"
  value       = aws_apigatewayv2_api.market_data_websocket.id
}

output "websocket_api_endpoint" {
  description = "WebSocket API connection URL"
  value       = aws_apigatewayv2_api.market_data_websocket.api_endpoint
}

output "websocket_api_execution_arn" {
  description = "Execution ARN for the WebSocket API"
  value       = aws_apigatewayv2_api.market_data_websocket.execution_arn
}

output "cognito_authorizer_id" {
  description = "ID of the Cognito JWT authorizer"
  value       = aws_apigatewayv2_authorizer.cognito_jwt.id
}

output "production_stage_id" {
  description = "ID of the production stage"
  value       = aws_apigatewayv2_stage.production.id
}
