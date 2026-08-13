#!/usr/bin/env bash
# =============================================================================
# TFLint Tests
# Runs TFLint with AWS ruleset across all Terraform modules.
# Usage: bash tests/terraform/test_tflint.sh
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

log_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; ((PASS++)); }
log_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; ((FAIL++)); }

echo "=============================================="
echo "  TFLint Tests (AWS Ruleset)"
echo "=============================================="
echo ""

# Check if tflint is available
if ! command -v tflint &> /dev/null; then
    echo -e "${YELLOW}WARNING: tflint not found. Skipping lint tests.${NC}"
    echo "Install: brew install tflint (macOS) or curl -s https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash"
    exit 0
fi

# Create temporary .tflint.hcl if not exists
TFLINT_CONFIG="${TF_DIR}/.tflint.hcl"
if [ ! -f "${TFLINT_CONFIG}" ]; then
    cat > /tmp/.tflint.hcl << 'EOF'
plugin "aws" {
  enabled = true
  version = "0.30.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

config {
  call_module_type = "local"
}

rule "terraform_naming_convention" {
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}
EOF
    TFLINT_CONFIG="/tmp/.tflint.hcl"
fi

# Initialize tflint plugins
echo "Initializing TFLint plugins..."
tflint --init --config="${TFLINT_CONFIG}" 2>/dev/null || true

# Run tflint on root module
echo "--- TFLint: Root module ---"
if tflint --config="${TFLINT_CONFIG}" --chdir="${TF_DIR}" 2>/dev/null; then
    log_pass "Root module (no issues)"
else
    log_fail "Root module has lint issues"
fi

# Run tflint on each submodule
echo "--- TFLint: Submodules ---"
MODULES_DIR="${TF_DIR}/modules"
if [ -d "${MODULES_DIR}" ]; then
    for module_dir in "${MODULES_DIR}"/*/; do
        module_name=$(basename "${module_dir}")
        if tflint --config="${TFLINT_CONFIG}" --chdir="${module_dir}" 2>/dev/null; then
            log_pass "module: ${module_name}"
        else
            log_fail "module: ${module_name}"
        fi
    done
fi

# Summary
echo ""
echo "=============================================="
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "=============================================="

if [ ${FAIL} -gt 0 ]; then
    exit 1
fi
exit 0
