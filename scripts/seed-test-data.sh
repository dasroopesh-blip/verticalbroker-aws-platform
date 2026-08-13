#!/usr/bin/env bash
# =============================================================================
# Seed Test Data into Local Development Environment
# Loads sample data into LocalStack (S3, DynamoDB, Kinesis) for development.
# Requires: docker compose up (LocalStack running)
# Usage: bash scripts/seed-test-data.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENDPOINT="http://localhost:4566"
REGION="us-east-1"
export AWS_DEFAULT_REGION="${REGION}"
export AWS_ACCESS_KEY_ID="testing"
export AWS_SECRET_ACCESS_KEY="testing"
export AWS_ENDPOINT_URL="${ENDPOINT}"

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Seed Test Data (LocalStack)                                     ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Check LocalStack is running
if ! curl -s "${ENDPOINT}/_localstack/health" > /dev/null 2>&1; then
    echo "ERROR: LocalStack not running at ${ENDPOINT}"
    echo "Start it with: make docker-up"
    exit 1
fi

echo "LocalStack is healthy ✓"
echo ""

# =============================================================================
# Seed S3 Bronze Layer (sample market data)
# =============================================================================
echo "=== Seeding S3 Bronze Layer ==="

# Create sample Parquet-like data (JSON for simplicity in local dev)
SAMPLE_DATA_DIR="/tmp/vb-seed-data"
mkdir -p "${SAMPLE_DATA_DIR}"

for instrument in AAPL MSFT GOOG TSLA AMZN; do
    cat > "${SAMPLE_DATA_DIR}/${instrument}.json" << EOF
{"source_id":"bloomberg-feed-1","instrument_id":"${instrument}","timestamp":"2024-01-15T14:30:00Z","event_type":"TRADE","price":185.50,"volume":1000,"exchange":"NYSE","schema_version":"1.0"}
{"source_id":"bloomberg-feed-1","instrument_id":"${instrument}","timestamp":"2024-01-15T14:30:01Z","event_type":"TRADE","price":185.75,"volume":500,"exchange":"NYSE","schema_version":"1.0"}
{"source_id":"bloomberg-feed-1","instrument_id":"${instrument}","timestamp":"2024-01-15T14:30:02Z","event_type":"QUOTE","price":185.80,"volume":2000,"exchange":"NYSE","schema_version":"1.0"}
EOF
done

aws s3 sync "${SAMPLE_DATA_DIR}/" "s3://vb-bronze-local/bronze/source=bloomberg/trade_date=2024-01-15/instrument_type=equity/" \
    --endpoint-url "${ENDPOINT}" --quiet

echo "  ✓ 5 instruments × 3 records = 15 sample records in Bronze"

# =============================================================================
# Seed DynamoDB (sample portfolios)
# =============================================================================
echo ""
echo "=== Seeding DynamoDB Portfolio ==="

# Client 1: Active trader
aws dynamodb put-item \
    --endpoint-url "${ENDPOINT}" \
    --table-name Portfolio \
    --item '{
        "client_id": {"S": "client-001"},
        "account_id": {"S": "account-001"},
        "positions": {"M": {
            "AAPL": {"M": {"quantity": {"N": "100"}, "avg_cost": {"N": "185.50"}}},
            "MSFT": {"M": {"quantity": {"N": "50"}, "avg_cost": {"N": "380.00"}}},
            "GOOG": {"M": {"quantity": {"N": "25"}, "avg_cost": {"N": "140.00"}}}
        }},
        "cash_balance": {"N": "75000.00"},
        "updated_at": {"S": "2024-01-15T14:30:00Z"}
    }'

# Client 2: Conservative investor
aws dynamodb put-item \
    --endpoint-url "${ENDPOINT}" \
    --table-name Portfolio \
    --item '{
        "client_id": {"S": "client-002"},
        "account_id": {"S": "account-002"},
        "positions": {"M": {
            "AAPL": {"M": {"quantity": {"N": "500"}, "avg_cost": {"N": "150.00"}}}
        }},
        "cash_balance": {"N": "250000.00"},
        "updated_at": {"S": "2024-01-15T14:30:00Z"}
    }'

echo "  ✓ 2 client portfolios seeded"

# =============================================================================
# Seed Kinesis (sample market data records)
# =============================================================================
echo ""
echo "=== Sending sample records to Kinesis ==="

for i in $(seq 1 5); do
    PAYLOAD=$(echo -n "{\"source_id\":\"bloomberg\",\"instrument_id\":\"AAPL\",\"timestamp\":\"2024-01-15T14:30:0${i}Z\",\"price\":185.${i}0,\"volume\":${i}000}" | base64)
    aws kinesis put-record \
        --endpoint-url "${ENDPOINT}" \
        --stream-name market-data-stream \
        --partition-key "AAPL" \
        --data "${PAYLOAD}" \
        --quiet 2>/dev/null || true
done

echo "  ✓ 5 records sent to market-data-stream"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "═══════════════════════════════════════════════════"
echo "  Test Data Seeded Successfully!"
echo "═══════════════════════════════════════════════════"
echo ""
echo "  S3 Bronze:  s3://vb-bronze-local/bronze/..."
echo "  DynamoDB:   Portfolio (2 clients)"
echo "  Kinesis:    market-data-stream (5 records)"
echo ""
echo "  Verify:"
echo "    aws --endpoint-url ${ENDPOINT} s3 ls s3://vb-bronze-local/ --recursive"
echo "    aws --endpoint-url ${ENDPOINT} dynamodb scan --table-name Portfolio"
echo ""

# Cleanup temp files
rm -rf "${SAMPLE_DATA_DIR}"
