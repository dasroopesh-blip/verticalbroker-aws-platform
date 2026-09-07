#!/usr/bin/env bash
# Build the worker Lambda deployment package (worker.zip).
#
# Bundles the filings_assistant package + runtime dependencies into a zip that
# Terraform's compute module deploys. Run before `make tf-apply`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT}/build/lambda"
ARTIFACT_DIR="${ROOT}/terraform/modules/compute/artifacts"
ZIP_PATH="${ARTIFACT_DIR}/worker.zip"

echo "==> Cleaning build directory"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}" "${ARTIFACT_DIR}"

echo "==> Installing runtime dependencies into package"
python -m pip install --quiet --target "${BUILD_DIR}" \
  "boto3" "aws-lambda-powertools[all]" "pydantic>=2.5" "pydantic-settings" \
  "opensearch-py" "httpx"

echo "==> Copying application code"
cp -r "${ROOT}/src/filings_assistant" "${BUILD_DIR}/filings_assistant"

echo "==> Creating ${ZIP_PATH}"
(cd "${BUILD_DIR}" && zip -qr "${ZIP_PATH}" .)

echo "==> Done: ${ZIP_PATH}"
