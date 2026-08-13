#!/usr/bin/env bash
# =============================================================================
# Deploy Glue Scripts to S3
# Syncs ETL scripts to the Glue scripts bucket for the target environment.
# Usage: bash scripts/deploy-glue-scripts.sh [dev|staging|production]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV="${1:-dev}"
REGION="${AWS_REGION:-us-east-1}"

# Environment-specific bucket names
case "${ENV}" in
    dev)
        BUCKET="vb-glue-scripts-dev"
        KMS_KEY_ALIAS="alias/verticalbroker-internal-dev"
        ;;
    staging)
        BUCKET="vb-glue-scripts-staging"
        KMS_KEY_ALIAS="alias/verticalbroker-internal-staging"
        ;;
    production)
        BUCKET="vb-glue-scripts-prod"
        KMS_KEY_ALIAS="alias/verticalbroker-confidential-prod"
        ;;
    *)
        echo "ERROR: Invalid environment '${ENV}'. Use: dev, staging, or production"
        exit 1
        ;;
esac

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Deploy Glue Scripts                                             ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Environment: ${ENV}"
echo "  Bucket:      s3://${BUCKET}"
echo "  Region:      ${REGION}"
echo "  KMS Key:     ${KMS_KEY_ALIAS}"
echo ""

# Confirm production deployments
if [[ "${ENV}" == "production" ]]; then
    read -p "⚠️  Deploy to PRODUCTION? (type 'yes' to confirm): " confirm
    if [[ "${confirm}" != "yes" ]]; then
        echo "Deployment cancelled."
        exit 0
    fi
fi

# Sync ETL scripts
echo "Syncing ETL scripts..."
aws s3 sync "${REPO_ROOT}/src/etl/" "s3://${BUCKET}/src/etl/" \
    --delete \
    --sse aws:kms \
    --sse-kms-key-id "${KMS_KEY_ALIAS}" \
    --exclude "*.pyc" \
    --exclude "__pycache__/*" \
    --region "${REGION}"

# Sync common utilities (used by Glue jobs)
echo "Syncing common utilities..."
aws s3 sync "${REPO_ROOT}/src/common/" "s3://${BUCKET}/src/common/" \
    --delete \
    --sse aws:kms \
    --sse-kms-key-id "${KMS_KEY_ALIAS}" \
    --exclude "*.pyc" \
    --exclude "__pycache__/*" \
    --region "${REGION}"

# Sync models (used by Glue jobs)
echo "Syncing data models..."
aws s3 sync "${REPO_ROOT}/src/models/" "s3://${BUCKET}/src/models/" \
    --delete \
    --sse aws:kms \
    --sse-kms-key-id "${KMS_KEY_ALIAS}" \
    --exclude "*.pyc" \
    --exclude "__pycache__/*" \
    --region "${REGION}"

echo ""
echo "✓ Glue scripts deployed to s3://${BUCKET}/"
echo ""
echo "  Verify:"
echo "    aws s3 ls s3://${BUCKET}/src/etl/ --region ${REGION}"
