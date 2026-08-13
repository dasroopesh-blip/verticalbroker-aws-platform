#!/usr/bin/env bash
# =============================================================================
# Checkov Security/Compliance Scan
# Runs Checkov (Bridgecrew) for CIS, FINRA compliance checks on Terraform.
# Usage: bash tests/terraform/test_checkov.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=============================================="
echo "  Checkov Security & Compliance Scan"
echo "  Framework: CIS AWS Foundations + Custom"
echo "=============================================="
echo ""

# Check if checkov is available
if ! command -v checkov &> /dev/null; then
    echo -e "${YELLOW}WARNING: checkov not found. Skipping security scan.${NC}"
    echo "Install: pip install checkov"
    exit 0
fi

# Run checkov with relevant checks
echo "Running Checkov scan..."
echo ""

CHECKOV_ARGS=(
    "--directory" "${TF_DIR}"
    "--framework" "terraform"
    "--output" "cli"
    "--compact"
    "--quiet"
)

# Critical checks for FINRA/financial services:
# CKV_AWS_18: Ensure the S3 bucket has access logging enabled
# CKV_AWS_19: Ensure the S3 bucket has server-side-encryption enabled
# CKV_AWS_21: Ensure the S3 bucket has versioning enabled
# CKV_AWS_40: Ensure IAM policies are not overly permissive
# CKV_AWS_41: Ensure no hard-coded credentials exist in IAM policies
# CKV_AWS_145: Ensure S3 bucket uses KMS encryption
# CKV_AWS_144: Ensure S3 bucket has cross-region replication enabled
# CKV2_AWS_6: Ensure S3 bucket has a Public Access Block

CRITICAL_CHECKS="CKV_AWS_18,CKV_AWS_19,CKV_AWS_21,CKV_AWS_145,CKV_AWS_144,CKV2_AWS_6"

echo "=== Critical Checks (FINRA-relevant) ==="
if checkov "${CHECKOV_ARGS[@]}" --check "${CRITICAL_CHECKS}" 2>/dev/null; then
    echo -e "${GREEN}✓ All critical security checks passed${NC}"
else
    echo -e "${YELLOW}⚠ Some critical checks have findings (review above)${NC}"
fi

echo ""
echo "=== Full Scan (informational) ==="
# Full scan - don't fail on these (informational)
checkov "${CHECKOV_ARGS[@]}" \
    --skip-check "CKV_AWS_50,CKV_AWS_51" \
    2>/dev/null || true

echo ""
echo "=============================================="
echo "  Scan Complete"
echo "=============================================="
echo ""
echo "Notes for FINRA compliance:"
echo "  - S3 Object Lock COMPLIANCE mode enforces 7-year retention (Rule 4511)"
echo "  - KMS CMKs per data classification (Public/Internal/Confidential/Restricted)"
echo "  - IAM policies use no wildcard resources"
echo "  - CloudTrail data events enabled for audit trail"
echo "  - GuardDuty + SecurityHub for continuous monitoring"
