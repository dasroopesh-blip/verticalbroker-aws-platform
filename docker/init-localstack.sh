#!/bin/bash
# =============================================================================
# LocalStack Initialization Script
# Creates AWS resources for local development environment.
# Runs automatically when LocalStack container starts.
# =============================================================================

set -e

echo "=== Initializing VerticalBroker LocalStack Environment ==="

ENDPOINT="http://localhost:4566"
REGION="us-east-1"
export AWS_DEFAULT_REGION="${REGION}"
export AWS_ACCESS_KEY_ID="testing"
export AWS_SECRET_ACCESS_KEY="testing"

# S3 Buckets (Medallion Architecture)
echo "Creating S3 buckets..."
awslocal s3 mb s3://vb-bronze-local
awslocal s3 mb s3://vb-silver-local
awslocal s3 mb s3://vb-gold-local
awslocal s3 mb s3://vb-regulatory-local
awslocal s3 mb s3://vb-glue-scripts-local
awslocal s3 mb s3://vb-artifacts-local

# DynamoDB Tables
echo "Creating DynamoDB tables..."
awslocal dynamodb create-table \
    --table-name IdempotencyStore \
    --key-schema AttributeName=id,KeyType=HASH \
    --attribute-definitions AttributeName=id,AttributeType=S \
    --billing-mode PAY_PER_REQUEST

awslocal dynamodb create-table \
    --table-name CircuitBreakerState \
    --key-schema AttributeName=service_name,KeyType=HASH \
    --attribute-definitions AttributeName=service_name,AttributeType=S \
    --billing-mode PAY_PER_REQUEST

awslocal dynamodb create-table \
    --table-name Orders \
    --key-schema AttributeName=order_id,KeyType=HASH \
    --attribute-definitions AttributeName=order_id,AttributeType=S \
    --billing-mode PAY_PER_REQUEST

awslocal dynamodb create-table \
    --table-name OrderOutbox \
    --key-schema AttributeName=pk,KeyType=HASH AttributeName=sk,KeyType=RANGE \
    --attribute-definitions AttributeName=pk,AttributeType=S AttributeName=sk,AttributeType=S \
    --billing-mode PAY_PER_REQUEST

awslocal dynamodb create-table \
    --table-name Portfolio \
    --key-schema AttributeName=client_id,KeyType=HASH AttributeName=account_id,KeyType=RANGE \
    --attribute-definitions AttributeName=client_id,AttributeType=S AttributeName=account_id,AttributeType=S \
    --billing-mode PAY_PER_REQUEST

# Kinesis Stream
echo "Creating Kinesis stream..."
awslocal kinesis create-stream \
    --stream-name market-data-stream \
    --shard-count 4

# SQS Queues
echo "Creating SQS queues..."
awslocal sqs create-queue --queue-name market-data-dlq
awslocal sqs create-queue \
    --queue-name trade-processing.fifo \
    --attributes FifoQueue=true,ContentBasedDeduplication=true
awslocal sqs create-queue --queue-name trade-processing-dlq.fifo \
    --attributes FifoQueue=true

# EventBridge
echo "Creating EventBridge event bus..."
awslocal events create-event-bus --name verticalbroker-platform-local

echo ""
echo "=== LocalStack Initialization Complete ==="
echo "  S3 Buckets: vb-bronze-local, vb-silver-local, vb-gold-local, vb-regulatory-local"
echo "  DynamoDB: IdempotencyStore, CircuitBreakerState, Orders, OrderOutbox, Portfolio"
echo "  Kinesis: market-data-stream (4 shards)"
echo "  SQS: market-data-dlq, trade-processing.fifo"
echo "  EventBridge: verticalbroker-platform-local"
echo ""
echo "  Endpoint: ${ENDPOINT}"
echo "  Region: ${REGION}"
