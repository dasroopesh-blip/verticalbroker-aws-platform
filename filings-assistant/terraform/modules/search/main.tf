# ===========================================================================
# Search module: Amazon OpenSearch Service domain (vector + text).
#
# LEARNING NOTE: This is the managed OpenSearch cluster that stores chunk
# embeddings (k-NN) and analyzed text (BM25) for hybrid search. It is the most
# expensive component, so the dev default is a single t3.small.search node.
# It lives in the VPC and is encrypted at rest with our KMS key.
#
# COST TIP: run `terraform destroy` when you're not actively demoing — an idle
# OpenSearch domain still bills per hour.
# ===========================================================================

variable "name_prefix" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "instance_count" {
  type = number
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "ingress_cidrs" {
  type = list(string)
}

variable "kms_key_arn" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

# Security group: allow HTTPS (443) to OpenSearch from within the VPC only.
resource "aws_security_group" "os" {
  name        = "${var.name_prefix}-os-sg"
  description = "Allow HTTPS to OpenSearch from within the VPC"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.ingress_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_opensearch_domain" "this" {
  domain_name    = "${var.name_prefix}-search"
  engine_version = "OpenSearch_2.13"

  cluster_config {
    instance_type          = var.instance_type
    instance_count         = var.instance_count
    zone_awareness_enabled = var.instance_count > 1
  }

  ebs_options {
    ebs_enabled = true
    volume_size = 10 # GB; enough for a dev corpus
    volume_type = "gp3"
  }

  # Deploy into a single private subnet for dev (multi-AZ needs >1 node).
  vpc_options {
    subnet_ids         = [var.subnet_ids[0]]
    security_group_ids = [aws_security_group.os.id]
  }

  encrypt_at_rest {
    enabled    = true
    kms_key_id = var.kms_key_arn
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  tags = var.tags
}

output "endpoint" {
  value = aws_opensearch_domain.this.endpoint
}

output "arn" {
  value = aws_opensearch_domain.this.arn
}
