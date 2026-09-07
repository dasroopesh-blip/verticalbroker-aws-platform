# ---------------------------------------------------------------------------
# Root module — wires the child modules together.
#
# LEARNING NOTE: this file is the "main()" of your infrastructure. It configures
# the AWS provider, defines common tags, and calls each module, passing outputs
# from one module (e.g. VPC subnet IDs) as inputs to the next. Terraform figures
# out the dependency order automatically from these references.
# ---------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region

  # Apply consistent tags to every taggable resource (a project convention:
  # Project / Environment / ManagedBy are required on all resources).
  default_tags {
    tags = local.common_tags
  }
}

locals {
  name_prefix = "${var.project}-${var.environment}"
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# --- Networking: VPC + private subnets the data services live in ------------
module "networking" {
  source      = "./modules/networking"
  name_prefix = local.name_prefix
  vpc_cidr    = var.vpc_cidr
  tags        = local.common_tags
}

# --- Security: KMS key + IAM roles/policies (incl. Bedrock access) ----------
module "security" {
  source                     = "./modules/security"
  name_prefix                = local.name_prefix
  aws_region                 = var.aws_region
  bedrock_reasoning_model_id = var.bedrock_reasoning_model_id
  bedrock_embedding_model_id = var.bedrock_embedding_model_id
  tags                       = local.common_tags
}

# --- Queue: SQS ingest queue + dead-letter queue ----------------------------
module "queue" {
  source      = "./modules/queue"
  name_prefix = local.name_prefix
  kms_key_arn = module.security.kms_key_arn
  tags        = local.common_tags
}

# --- Database: RDS Postgres source of truth ---------------------------------
module "database" {
  source             = "./modules/database"
  name_prefix        = local.name_prefix
  instance_class     = var.db_instance_class
  vpc_id             = module.networking.vpc_id
  subnet_ids         = module.networking.private_subnet_ids
  kms_key_arn        = module.security.kms_key_arn
  ingress_cidrs      = [var.vpc_cidr]
  tags               = local.common_tags
}

# --- Search: Amazon OpenSearch (vector + text) ------------------------------
module "search" {
  source          = "./modules/search"
  name_prefix     = local.name_prefix
  instance_type   = var.opensearch_instance_type
  instance_count  = var.opensearch_instance_count
  vpc_id          = module.networking.vpc_id
  subnet_ids      = module.networking.private_subnet_ids
  ingress_cidrs   = [var.vpc_cidr]
  kms_key_arn     = module.security.kms_key_arn
  tags            = local.common_tags
}

# --- Compute: Lambda worker (SQS-triggered indexing) ------------------------
module "compute" {
  source              = "./modules/compute"
  name_prefix         = local.name_prefix
  lambda_role_arn     = module.security.lambda_role_arn
  queue_arn           = module.queue.queue_arn
  subnet_ids          = module.networking.private_subnet_ids
  security_group_id   = module.networking.lambda_security_group_id
  opensearch_endpoint = module.search.endpoint
  environment_vars = {
    FA_RUN_MODE                    = "aws"
    FA_USE_MOCK_BEDROCK            = "false"
    AWS_REGION                     = var.aws_region
    FA_OPENSEARCH_HOST             = module.search.endpoint
    FA_BEDROCK_REASONING_MODEL_ID  = var.bedrock_reasoning_model_id
    FA_BEDROCK_EMBEDDING_MODEL_ID  = var.bedrock_embedding_model_id
    FA_ENABLE_RERANKING            = tostring(var.enable_reranker)
    FA_SAGEMAKER_RERANKER_ENDPOINT = var.enable_reranker ? module.reranker[0].endpoint_name : ""
  }
  tags = local.common_tags
}

# --- Reranker: SageMaker cross-encoder endpoint (Stage 2 ranking) -----------
# Opt-in: set enable_reranker=true (and provide model artifact + image) to
# deploy. When off, the app uses the fused ranking / local reranker instead.
module "reranker" {
  count              = var.enable_reranker ? 1 : 0
  source             = "./modules/reranker"
  name_prefix        = local.name_prefix
  model_data_url     = var.reranker_model_data_url
  image_uri          = var.reranker_image_uri
  execution_role_arn = module.security.sagemaker_role_arn
  instance_type      = var.reranker_instance_type
  kms_key_arn        = module.security.kms_key_arn
  tags               = local.common_tags
}

# --- Monitoring: budget alarm + SNS alerts ----------------------------------
module "monitoring" {
  source             = "./modules/monitoring"
  name_prefix        = local.name_prefix
  monthly_budget_usd = var.monthly_budget_usd
  alert_email        = var.budget_alert_email
  tags               = local.common_tags
}
