#!/usr/bin/env bash
# =============================================================================
# Run Database Migrations (Aurora PostgreSQL)
# Applies schema changes to the Aurora PostgreSQL database.
# Usage: bash scripts/run-migrations.sh [dev|staging|production]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV="${1:-dev}"
REGION="${AWS_REGION:-us-east-1}"

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Aurora PostgreSQL Migration Runner                              ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Environment: ${ENV}"
echo "  Region:      ${REGION}"
echo ""

# =============================================================================
# Resolve database connection from AWS Secrets Manager
# =============================================================================
resolve_connection() {
    local env=$1

    if [[ "${env}" == "local" ]]; then
        # Local Docker PostgreSQL
        export PGHOST="localhost"
        export PGPORT="5432"
        export PGDATABASE="verticalbroker"
        export PGUSER="vb_admin"
        export PGPASSWORD="local_dev_only"
        return
    fi

    echo "Retrieving database credentials from Secrets Manager..."
    SECRET_NAME="verticalbroker/${env}/aurora-credentials"

    SECRET_VALUE=$(aws secretsmanager get-secret-value \
        --secret-id "${SECRET_NAME}" \
        --region "${REGION}" \
        --query 'SecretString' \
        --output text)

    export PGHOST=$(echo "${SECRET_VALUE}" | jq -r '.host')
    export PGPORT=$(echo "${SECRET_VALUE}" | jq -r '.port')
    export PGDATABASE=$(echo "${SECRET_VALUE}" | jq -r '.dbname')
    export PGUSER=$(echo "${SECRET_VALUE}" | jq -r '.username')
    export PGPASSWORD=$(echo "${SECRET_VALUE}" | jq -r '.password')

    echo "  Host: ${PGHOST}"
    echo "  Port: ${PGPORT}"
    echo "  DB:   ${PGDATABASE}"
    echo "  User: ${PGUSER}"
}

# =============================================================================
# Run migrations
# =============================================================================
run_migrations() {
    echo ""
    echo "Running migrations..."

    # Apply schema from init-postgres.sql (idempotent with IF NOT EXISTS)
    psql -f "${REPO_ROOT}/docker/init-postgres.sql" 2>&1 | while IFS= read -r line; do
        echo "  ${line}"
    done

    echo ""
    echo "✓ Migrations applied successfully"
}

# =============================================================================
# Production safety check
# =============================================================================
if [[ "${ENV}" == "production" ]]; then
    echo "⚠️  WARNING: Running migrations against PRODUCTION database!"
    read -p "Type 'MIGRATE' to confirm: " confirm
    if [[ "${confirm}" != "MIGRATE" ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

# Check for psql
if ! command -v psql &> /dev/null; then
    echo "ERROR: psql not found. Install PostgreSQL client:"
    echo "  brew install postgresql (macOS)"
    echo "  apt-get install postgresql-client (Ubuntu)"
    exit 1
fi

# Resolve and run
resolve_connection "${ENV}"
run_migrations
