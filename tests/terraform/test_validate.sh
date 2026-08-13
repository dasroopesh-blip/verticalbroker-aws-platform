#!/usr/bin/env bash
# =============================================================================
# Terraform Validation Tests
# Validates all Terraform modules and environment configurations.
# Usage: bash tests/terraform/test_validate.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

log_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; ((PASS++)); }
log_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; ((FAIL++)); }
log_skip() { echo -e "${YELLOW}⊘ SKIP${NC}: $1"; ((SKIP++)); }

echo "=============================================="
echo "  Terraform Validation Tests"
echo "  Repo: ${REPO_ROOT}"
echo "=============================================="
echo ""

# Check if terraform is available
if ! command -v terraform &> /dev/null; then
    echo -e "${YELLOW}WARNING: terraform not found. Skipping validation tests.${NC}"
    echo "Install terraform to run these tests: https://developer.hashicorp.com/terraform/downloads"
    exit 0
fi

# Test 1: terraform fmt check (all modules)
echo "--- Test: terraform fmt ---"
if terraform -chdir="${TF_DIR}" fmt -check -recursive -diff 2>/dev/null; then
    log_pass "terraform fmt (all files properly formatted)"
else
    log_fail "terraform fmt (files need formatting - run 'terraform fmt -recursive')"
fi

# Test 2: terraform validate (root module)
echo "--- Test: terraform validate (root) ---"
if cd "${TF_DIR}" && terraform init -backend=false -input=false 2>/dev/null && terraform validate 2>/dev/null; then
    log_pass "terraform validate (root module)"
else
    log_fail "terraform validate (root module)"
fi

# Test 3: Validate each module independently
echo "--- Test: Module validation ---"
MODULES_DIR="${TF_DIR}/modules"
if [ -d "${MODULES_DIR}" ]; then
    for module_dir in "${MODULES_DIR}"/*/; do
        module_name=$(basename "${module_dir}")
        if cd "${module_dir}" && terraform init -backend=false -input=false 2>/dev/null && terraform validate 2>/dev/null; then
            log_pass "module: ${module_name}"
        else
            log_fail "module: ${module_name}"
        fi
    done
else
    log_skip "No modules directory found"
fi

# Test 4: Check for hardcoded credentials (security check)
echo "--- Test: No hardcoded secrets ---"
SECRETS_FOUND=0
if grep -rl "AKIA[A-Z0-9]\{16\}" "${TF_DIR}" 2>/dev/null; then
    SECRETS_FOUND=1
fi
if grep -rl "aws_secret_access_key\s*=\s*\"[^\"]\+\"" "${TF_DIR}" 2>/dev/null; then
    SECRETS_FOUND=1
fi
if [ ${SECRETS_FOUND} -eq 0 ]; then
    log_pass "No hardcoded AWS credentials found"
else
    log_fail "Hardcoded credentials detected in Terraform files!"
fi

# Test 5: Check for wildcard IAM resources
echo "--- Test: No IAM wildcard resources ---"
if grep -rl '"Resource"\s*:\s*"\*"' "${TF_DIR}/modules/security/" 2>/dev/null | grep -v "\.terraform" | head -1 > /dev/null 2>&1; then
    log_fail "Wildcard IAM resources found (violates least-privilege)"
else
    log_pass "No wildcard IAM resources (least-privilege maintained)"
fi

# Test 6: Check all variables have descriptions
echo "--- Test: Variables have descriptions ---"
MISSING_DESC=$(grep -rl "^variable" "${TF_DIR}" 2>/dev/null | xargs grep -L "description" 2>/dev/null || true)
if [ -z "${MISSING_DESC}" ]; then
    log_pass "All variables have descriptions"
else
    log_fail "Variables missing descriptions: ${MISSING_DESC}"
fi

# Summary
echo ""
echo "=============================================="
echo "  Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "=============================================="

if [ ${FAIL} -gt 0 ]; then
    exit 1
fi
exit 0
