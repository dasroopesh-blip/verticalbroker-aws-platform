#!/usr/bin/env bash
# =============================================================================
# Build Lambda Deployment Packages
# Creates ZIP artifacts for Lambda layer + functions + Glue scripts.
# Output: build/lambda-layer.zip, build/lambda-functions.zip, build/glue-scripts.zip
# Usage: bash scripts/build-lambda.sh [--arm64]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
PYTHON_VERSION="3.12"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  VerticalBroker Lambda Package Builder                           ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Clean previous build
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}/layer/python/lib/python${PYTHON_VERSION}/site-packages"

# =============================================================================
# Step 1: Build Lambda Layer (dependencies)
# =============================================================================
echo -e "${GREEN}[1/3]${NC} Building Lambda layer..."

PLATFORM_ARGS=""
if [[ "${1:-}" == "--arm64" ]]; then
    PLATFORM_ARGS="--platform manylinux2014_aarch64 --implementation cp --python-version ${PYTHON_VERSION} --only-binary=:all:"
    echo "  Target: ARM64 (Graviton2)"
else
    echo "  Target: native (use --arm64 for production builds)"
fi

pip install \
    -r "${REPO_ROOT}/requirements/lambda-layer.txt" \
    -t "${BUILD_DIR}/layer/python/lib/python${PYTHON_VERSION}/site-packages/" \
    --no-cache-dir \
    --quiet \
    ${PLATFORM_ARGS}

# Remove unnecessary files to reduce layer size
find "${BUILD_DIR}/layer" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "${BUILD_DIR}/layer" -name "*.dist-info" -exec rm -rf {} + 2>/dev/null || true
find "${BUILD_DIR}/layer" -name "*.egg-info" -exec rm -rf {} + 2>/dev/null || true
find "${BUILD_DIR}/layer" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
find "${BUILD_DIR}/layer" -name "*.pyi" -delete 2>/dev/null || true

# Package layer
cd "${BUILD_DIR}/layer"
zip -r "${BUILD_DIR}/lambda-layer.zip" python/ -x "*.pyc" -q
LAYER_SIZE=$(du -sh "${BUILD_DIR}/lambda-layer.zip" | cut -f1)
echo "  ✓ lambda-layer.zip (${LAYER_SIZE})"

# =============================================================================
# Step 2: Build Lambda Functions Package (source code)
# =============================================================================
echo -e "${GREEN}[2/3]${NC} Building Lambda functions package..."

cd "${REPO_ROOT}/src"
zip -r "${BUILD_DIR}/lambda-functions.zip" . \
    -x "__pycache__/*" \
    -x "*.pyc" \
    -x "etl/*" \
    -x "*.egg-info/*" \
    -x ".pytest_cache/*" \
    -q
FUNC_SIZE=$(du -sh "${BUILD_DIR}/lambda-functions.zip" | cut -f1)
echo "  ✓ lambda-functions.zip (${FUNC_SIZE})"

# =============================================================================
# Step 3: Build Glue Scripts Package
# =============================================================================
echo -e "${GREEN}[3/3]${NC} Building Glue scripts package..."

mkdir -p "${BUILD_DIR}/glue"
cp -r "${REPO_ROOT}/src/etl/"* "${BUILD_DIR}/glue/"
cp -r "${REPO_ROOT}/src/common/"* "${BUILD_DIR}/glue/"
cp -r "${REPO_ROOT}/src/models/"* "${BUILD_DIR}/glue/" 2>/dev/null || true

cd "${BUILD_DIR}/glue"
zip -r "${BUILD_DIR}/glue-scripts.zip" . -x "*.pyc" -x "__pycache__/*" -q
GLUE_SIZE=$(du -sh "${BUILD_DIR}/glue-scripts.zip" | cut -f1)
echo "  ✓ glue-scripts.zip (${GLUE_SIZE})"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "═══════════════════════════════════════════════════"
echo "  Build Complete!"
echo "═══════════════════════════════════════════════════"
echo ""
echo "  ${BUILD_DIR}/lambda-layer.zip      (${LAYER_SIZE})"
echo "  ${BUILD_DIR}/lambda-functions.zip  (${FUNC_SIZE})"
echo "  ${BUILD_DIR}/glue-scripts.zip     (${GLUE_SIZE})"
echo ""
echo "  Deploy with:"
echo "    aws lambda publish-layer-version --layer-name vb-deps --zip-file fileb://build/lambda-layer.zip"
echo "    aws lambda update-function-code --function-name <name> --zip-file fileb://build/lambda-functions.zip"
echo "    aws s3 sync build/glue/ s3://<bucket>/src/etl/"
