# ===========================================================================
# Database module: RDS PostgreSQL — the source of truth for raw filings.
#
# LEARNING NOTE: OpenSearch is a rebuildable index; Postgres is the durable
# record. It lives in private subnets, encrypted with our KMS key, reachable
# only from inside the VPC (via a security group). db.t3.micro keeps dev cheap.
# The password is generated and stored in Secrets Manager — never hardcoded.
# ===========================================================================

variable "name_prefix" {
  type = string
}

variable "instance_class" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "kms_key_arn" {
  type = string
}

variable "ingress_cidrs" {
  description = "CIDRs allowed to reach Postgres on 5432 (the VPC)."
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}

# Group the subnets RDS may place the instance in.
resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db-subnets"
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

# Security group: allow Postgres (5432) only from inside the VPC.
resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db-sg"
  description = "Allow Postgres from within the VPC"
  vpc_id      = var.vpc_id

  ingress {
    description = "Postgres from VPC"
    from_port   = 5432
    to_port     = 5432
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

# Generate a strong random password rather than hardcoding one.
resource "random_password" "db" {
  length  = 24
  special = true
}

resource "aws_secretsmanager_secret" "db" {
  name       = "${var.name_prefix}-db-credentials"
  kms_key_id = var.kms_key_arn
  tags       = var.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({ username = "fa_admin", password = random_password.db.result })
}

resource "aws_db_instance" "this" {
  identifier              = "${var.name_prefix}-postgres"
  engine                  = "postgres"
  engine_version          = "16"
  instance_class          = var.instance_class
  allocated_storage       = 20
  db_name                 = "filings"
  username                = "fa_admin"
  password                = random_password.db.result
  db_subnet_group_name    = aws_db_subnet_group.this.name
  vpc_security_group_ids  = [aws_security_group.db.id]
  storage_encrypted       = true
  kms_key_id              = var.kms_key_arn
  skip_final_snapshot     = true # dev convenience; set false for prod
  backup_retention_period = 1    # bump for prod
  multi_az                = false # single-AZ for dev cost; true for prod HA
  tags                    = var.tags
}

output "endpoint" {
  value = aws_db_instance.this.address
}

output "secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}
