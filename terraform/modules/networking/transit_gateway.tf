# Transit Gateway Configuration
# VerticalBroker AWS Data Engineering Platform
#
# Implements AWS Transit Gateway with route tables isolating production from non-production.
# TGW serves as the central hub for inter-account connectivity.
#
# Requirements: 20.2 (Transit Gateway inter-account connectivity with route isolation)

# ---------------------------------------------------------
# TRANSIT GATEWAY
# Central networking hub for cross-account, cross-VPC connectivity
# ---------------------------------------------------------

resource "aws_ec2_transit_gateway" "main" {
  count = var.enable_transit_gateway && var.transit_gateway_id == "" ? 1 : 0

  description                     = "VerticalBroker Transit Gateway - ${var.environment} hub"
  amazon_side_asn                 = var.transit_gateway_asn
  auto_accept_shared_attachments  = "disable" # Explicit attachment acceptance required
  default_route_table_association = "disable" # Use explicit route table associations
  default_route_table_propagation = "disable" # Use explicit route table propagations
  dns_support                     = "enable"
  vpn_ecmp_support                = "enable"
  multicast_support               = "disable"

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-tgw"
    Purpose = "Central Transit Gateway for cross-account connectivity"
  })
}

# ---------------------------------------------------------
# TRANSIT GATEWAY VPC ATTACHMENT
# Attach the production VPC to the Transit Gateway
# ---------------------------------------------------------

resource "aws_ec2_transit_gateway_vpc_attachment" "production" {
  count = var.enable_transit_gateway ? 1 : 0

  transit_gateway_id = local.transit_gateway_id
  vpc_id             = aws_vpc.main.id
  subnet_ids         = aws_subnet.data[*].id

  # Disable default route table association - use explicit
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  # Enable DNS support through TGW
  dns_support = "enable"

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-tgw-attachment-prod"
    Purpose = "Production VPC attachment to Transit Gateway"
  })
}

# ---------------------------------------------------------
# TRANSIT GATEWAY ROUTE TABLES
# Separate route tables for production and non-production isolation
# Requirement 20.2: Route tables isolating prod from non-prod
# ---------------------------------------------------------

# Production route table - only allows routes to shared services
resource "aws_ec2_transit_gateway_route_table" "production" {
  count = var.enable_transit_gateway && var.transit_gateway_id == "" ? 1 : 0

  transit_gateway_id = local.transit_gateway_id

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-tgw-rt-production"
    Purpose = "Production route table - isolated from non-production"
    Tier    = "production"
  })
}

# Non-production route table - allows routes to shared services only
resource "aws_ec2_transit_gateway_route_table" "non_production" {
  count = var.enable_transit_gateway && var.transit_gateway_id == "" ? 1 : 0

  transit_gateway_id = local.transit_gateway_id

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-tgw-rt-non-production"
    Purpose = "Non-production route table - isolated from production"
    Tier    = "non-production"
  })
}

# Shared services route table - can reach both prod and non-prod
resource "aws_ec2_transit_gateway_route_table" "shared_services" {
  count = var.enable_transit_gateway && var.transit_gateway_id == "" ? 1 : 0

  transit_gateway_id = local.transit_gateway_id

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-tgw-rt-shared-services"
    Purpose = "Shared services route table - reaches all environments"
    Tier    = "shared-services"
  })
}

# ---------------------------------------------------------
# ROUTE TABLE ASSOCIATIONS
# Associate production VPC attachment with production route table
# ---------------------------------------------------------

resource "aws_ec2_transit_gateway_route_table_association" "production" {
  count = var.enable_transit_gateway ? 1 : 0

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.production[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.production[0].id
}

# ---------------------------------------------------------
# ROUTE TABLE PROPAGATIONS
# Production only propagates to shared services (not to non-prod)
# ---------------------------------------------------------

resource "aws_ec2_transit_gateway_route_table_propagation" "prod_to_shared" {
  count = var.enable_transit_gateway && var.transit_gateway_id == "" ? 1 : 0

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.production[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.shared_services[0].id
}

# ---------------------------------------------------------
# BLACKHOLE ROUTES
# Explicitly deny traffic between production and non-production
# Requirement 20.2: Route tables denying all prod-to-nonprod traffic
# ---------------------------------------------------------

# Blackhole routes on production route table for non-production CIDRs
resource "aws_ec2_transit_gateway_route" "prod_blackhole_nonprod" {
  count = var.enable_transit_gateway && var.transit_gateway_id == "" ? length(var.non_production_vpc_cidrs) : 0

  destination_cidr_block         = var.non_production_vpc_cidrs[count.index]
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.production[0].id
  blackhole                      = true
}

# Blackhole routes on non-production route table for production VPC CIDR
resource "aws_ec2_transit_gateway_route" "nonprod_blackhole_prod" {
  count = var.enable_transit_gateway && var.transit_gateway_id == "" ? 1 : 0

  destination_cidr_block         = var.vpc_cidr
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.non_production[0].id
  blackhole                      = true
}

# ---------------------------------------------------------
# VPC ROUTE TABLE ENTRIES
# Add Transit Gateway routes to VPC route tables
# ---------------------------------------------------------

resource "aws_route" "data_to_tgw" {
  count = var.enable_transit_gateway ? length(var.non_production_vpc_cidrs) : 0

  route_table_id         = aws_route_table.data.id
  destination_cidr_block = var.non_production_vpc_cidrs[count.index]
  transit_gateway_id     = local.transit_gateway_id
}

resource "aws_route" "compute_to_tgw" {
  count = var.enable_transit_gateway ? length(var.non_production_vpc_cidrs) : 0

  route_table_id         = aws_route_table.compute.id
  destination_cidr_block = var.non_production_vpc_cidrs[count.index]
  transit_gateway_id     = local.transit_gateway_id
}

# ---------------------------------------------------------
# TRANSIT GATEWAY SHARING (RAM)
# Share Transit Gateway across accounts in the Organization
# ---------------------------------------------------------

resource "aws_ram_resource_share" "tgw" {
  count = var.enable_transit_gateway && var.transit_gateway_id == "" ? 1 : 0

  name                      = "${var.name_prefix}-tgw-share"
  allow_external_principals = false # Organization-only sharing

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-tgw-ram-share"
    Purpose = "RAM share for Transit Gateway cross-account access"
  })
}

resource "aws_ram_resource_association" "tgw" {
  count = var.enable_transit_gateway && var.transit_gateway_id == "" ? 1 : 0

  resource_arn       = aws_ec2_transit_gateway.main[0].arn
  resource_share_arn = aws_ram_resource_share.tgw[0].arn
}

# ---------------------------------------------------------
# LOCAL COMPUTED VALUES
# ---------------------------------------------------------

locals {
  # Use existing or newly created Transit Gateway ID
  transit_gateway_id = var.transit_gateway_id != "" ? var.transit_gateway_id : (
    var.enable_transit_gateway ? aws_ec2_transit_gateway.main[0].id : ""
  )
}
