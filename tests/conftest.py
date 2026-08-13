"""
VerticalBroker Platform - Shared Test Fixtures
Provides reusable fixtures for all unit and integration tests.
Uses moto for AWS service mocking (no real AWS calls).
"""

import base64
import json
import os
import uuid
from datetime import UTC, datetime
from decimal import Decimal
from unittest.mock import MagicMock, patch

import boto3
import pytest
from moto import mock_aws


# ============================================================================
# Environment Setup (before any imports that use boto3)
# ============================================================================

@pytest.fixture(autouse=True)
def aws_environment(monkeypatch):
    """Set AWS environment variables for all tests."""
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SECURITY_TOKEN", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")
    monkeypatch.setenv("POWERTOOLS_SERVICE_NAME", "verticalbroker-test")
    monkeypatch.setenv("POWERTOOLS_METRICS_NAMESPACE", "VerticalBroker/Test")
    monkeypatch.setenv("LOG_LEVEL", "DEBUG")
    monkeypatch.setenv("ENVIRONMENT", "test")
    # Lambda-specific
    monkeypatch.setenv("BRONZE_BUCKET", "vb-bronze-test")
    monkeypatch.setenv("SILVER_BUCKET", "vb-silver-test")
    monkeypatch.setenv("GOLD_BUCKET", "vb-gold-test")
    monkeypatch.setenv("REGULATORY_BUCKET", "vb-regulatory-test")
    monkeypatch.setenv("GLUE_DATABASE", "verticalbroker_test")
    monkeypatch.setenv("EVENT_BUS_NAME", "verticalbroker-platform-test")
    monkeypatch.setenv("DLQ_URL", "https://sqs.us-east-1.amazonaws.com/123456789012/market-data-dlq")
    monkeypatch.setenv("IDEMPOTENCY_TABLE", "IdempotencyStore")
    monkeypatch.setenv("CIRCUIT_BREAKER_TABLE", "CircuitBreakerState")
    monkeypatch.setenv("ORDERS_TABLE", "Orders")
    monkeypatch.setenv("OUTBOX_TABLE", "OrderOutbox")
    monkeypatch.setenv("PORTFOLIO_TABLE", "Portfolio")
    monkeypatch.setenv("SAGEMAKER_ENDPOINT", "advisory-model-endpoint-test")
    monkeypatch.setenv("MODEL_ENDPOINT_NAME", "advisory-model-endpoint-test")


# ============================================================================
# AWS Mock Fixtures
# ============================================================================

@pytest.fixture
def mock_aws_services():
    """Provides a full moto mock AWS environment."""
    with mock_aws():
        yield


@pytest.fixture
def s3_client(mock_aws_services):
    """Mocked S3 client with test buckets pre-created."""
    client = boto3.client("s3", region_name="us-east-1")
    for bucket in ["vb-bronze-test", "vb-silver-test", "vb-gold-test", "vb-regulatory-test"]:
        client.create_bucket(Bucket=bucket)
    return client


@pytest.fixture
def dynamodb_resource(mock_aws_services):
    """Mocked DynamoDB resource with all tables pre-created."""
    resource = boto3.resource("dynamodb", region_name="us-east-1")

    # Idempotency Store
    resource.create_table(
        TableName="IdempotencyStore",
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )

    # Circuit Breaker State
    resource.create_table(
        TableName="CircuitBreakerState",
        KeySchema=[{"AttributeName": "service_name", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "service_name", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )

    # Orders Table
    resource.create_table(
        TableName="Orders",
        KeySchema=[{"AttributeName": "order_id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "order_id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )

    # Order Outbox
    resource.create_table(
        TableName="OrderOutbox",
        KeySchema=[
            {"AttributeName": "pk", "KeyType": "HASH"},
            {"AttributeName": "sk", "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": "pk", "AttributeType": "S"},
            {"AttributeName": "sk", "AttributeType": "S"},
        ],
        BillingMode="PAY_PER_REQUEST",
    )

    # Portfolio Table
    resource.create_table(
        TableName="Portfolio",
        KeySchema=[
            {"AttributeName": "client_id", "KeyType": "HASH"},
            {"AttributeName": "account_id", "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": "client_id", "AttributeType": "S"},
            {"AttributeName": "account_id", "AttributeType": "S"},
        ],
        BillingMode="PAY_PER_REQUEST",
    )

    return resource


@pytest.fixture
def sqs_client(mock_aws_services):
    """Mocked SQS client with test queues."""
    client = boto3.client("sqs", region_name="us-east-1")
    # Standard DLQ
    client.create_queue(QueueName="market-data-dlq")
    # FIFO queue
    client.create_queue(
        QueueName="trade-processing.fifo",
        Attributes={"FifoQueue": "true", "ContentBasedDeduplication": "true"},
    )
    return client


@pytest.fixture
def eventbridge_client(mock_aws_services):
    """Mocked EventBridge client."""
    client = boto3.client("events", region_name="us-east-1")
    client.create_event_bus(Name="verticalbroker-platform-test")
    return client


@pytest.fixture
def glue_client(mock_aws_services):
    """Mocked Glue client."""
    return boto3.client("glue", region_name="us-east-1")


@pytest.fixture
def cloudwatch_client(mock_aws_services):
    """Mocked CloudWatch client."""
    return boto3.client("cloudwatch", region_name="us-east-1")


# ============================================================================
# Lambda Event Fixtures
# ============================================================================

@pytest.fixture
def sample_kinesis_event():
    """Valid Kinesis Data Streams batch event (market data)."""
    records = []
    for i in range(3):
        payload = {
            "source_id": f"bloomberg-{i}",
            "instrument_id": f"AAPL-{i}",
            "timestamp": datetime.now(UTC).isoformat(),
            "event_type": "TRADE",
            "price": 185.50 + i,
            "volume": 1000 + i * 100,
            "exchange": "NYSE",
            "schema_version": "1.0",
        }
        encoded = base64.b64encode(json.dumps(payload).encode("utf-8")).decode("utf-8")
        records.append({
            "kinesis": {
                "kinesisSchemaVersion": "1.0",
                "partitionKey": f"AAPL-{i}",
                "sequenceNumber": f"4958000000000000000000{i}",
                "data": encoded,
                "approximateArrivalTimestamp": 1704067200.0 + i,
            },
            "eventSource": "aws:kinesis",
            "eventVersion": "1.0",
            "eventID": f"shardId-000000000000:{uuid.uuid4()}",
            "eventName": "aws:kinesis:record",
            "invokeIdentityArn": "arn:aws:iam::123456789012:role/MarketDataLambdaRole",
            "awsRegion": "us-east-1",
            "eventSourceARN": "arn:aws:kinesis:us-east-1:123456789012:stream/market-data-stream",
        })
    return {"Records": records}


@pytest.fixture
def sample_api_gw_event():
    """Valid API Gateway HTTP API v2 event (POST /v1/orders)."""
    return {
        "version": "2.0",
        "routeKey": "POST /v1/orders",
        "rawPath": "/v1/orders",
        "rawQueryString": "",
        "headers": {
            "content-type": "application/json",
            "authorization": "Bearer test-jwt-token",
            "x-idempotency-key": str(uuid.uuid4()),
        },
        "requestContext": {
            "accountId": "123456789012",
            "apiId": "abc123def",
            "authorizer": {
                "jwt": {
                    "claims": {"sub": "client-001", "scope": "orders:write"},
                }
            },
            "http": {
                "method": "POST",
                "path": "/v1/orders",
                "sourceIp": "10.0.0.1",
            },
            "requestId": str(uuid.uuid4()),
            "stage": "$default",
            "time": "01/Jan/2024:00:00:00 +0000",
            "timeEpoch": 1704067200000,
        },
        "body": json.dumps({
            "instrument_id": "AAPL",
            "side": "BUY",
            "quantity": "100",
            "price": "185.50",
            "order_type": "LIMIT",
            "time_in_force": "GTC",
            "client_id": "client-001",
            "account_id": "account-001",
        }),
        "isBase64Encoded": False,
    }


@pytest.fixture
def sample_api_gw_get_event():
    """Valid API Gateway HTTP API v2 event (GET /v1/orders/{id})."""
    order_id = str(uuid.uuid4())
    return {
        "version": "2.0",
        "routeKey": f"GET /v1/orders/{order_id}",
        "rawPath": f"/v1/orders/{order_id}",
        "rawQueryString": "",
        "headers": {
            "authorization": "Bearer test-jwt-token",
        },
        "pathParameters": {"order_id": order_id},
        "requestContext": {
            "accountId": "123456789012",
            "apiId": "abc123def",
            "authorizer": {
                "jwt": {
                    "claims": {"sub": "client-001", "scope": "orders:read"},
                }
            },
            "http": {
                "method": "GET",
                "path": f"/v1/orders/{order_id}",
                "sourceIp": "10.0.0.1",
            },
            "requestId": str(uuid.uuid4()),
            "stage": "$default",
        },
        "isBase64Encoded": False,
    }


@pytest.fixture
def sample_sqs_fifo_event():
    """Valid SQS FIFO batch event (trade-processing.fifo)."""
    trade_event = {
        "order_id": str(uuid.uuid4()),
        "client_id": "client-001",
        "account_id": "account-001",
        "instrument_id": "AAPL",
        "side": "BUY",
        "quantity": "100",
        "price": "185.50",
        "executed_at": datetime.now(UTC).isoformat(),
        "correlation_id": str(uuid.uuid4()),
    }
    return {
        "Records": [
            {
                "messageId": str(uuid.uuid4()),
                "receiptHandle": "test-receipt-handle",
                "body": json.dumps(trade_event),
                "attributes": {
                    "ApproximateReceiveCount": "1",
                    "SentTimestamp": "1704067200000",
                    "SequenceNumber": "18849496460467696128",
                    "MessageGroupId": "client-001",
                    "MessageDeduplicationId": str(uuid.uuid4()),
                    "SenderId": "123456789012",
                    "ApproximateFirstReceiveTimestamp": "1704067200100",
                },
                "messageAttributes": {},
                "md5OfBody": "test-md5",
                "eventSource": "aws:sqs",
                "eventSourceARN": "arn:aws:sqs:us-east-1:123456789012:trade-processing.fifo",
                "awsRegion": "us-east-1",
            }
        ]
    }


@pytest.fixture
def sample_advisory_event():
    """Valid API Gateway event for POST /v1/advisory."""
    return {
        "version": "2.0",
        "routeKey": "POST /v1/advisory",
        "rawPath": "/v1/advisory",
        "rawQueryString": "",
        "headers": {
            "content-type": "application/json",
            "authorization": "Bearer test-jwt-token",
        },
        "requestContext": {
            "accountId": "123456789012",
            "apiId": "abc123def",
            "authorizer": {
                "jwt": {
                    "claims": {"sub": "client-001", "scope": "advisory:read"},
                }
            },
            "http": {"method": "POST", "path": "/v1/advisory", "sourceIp": "10.0.0.1"},
            "requestId": str(uuid.uuid4()),
            "stage": "$default",
        },
        "body": json.dumps({
            "client_id": "client-001",
            "account_id": "account-001",
            "risk_tolerance": "MODERATE",
            "investment_horizon": "LONG_TERM",
            "age": 35,
            "annual_income": "150000.00",
            "portfolio_value": "500000.00",
            "tax_filing_status": "SINGLE",
        }),
        "isBase64Encoded": False,
    }


# ============================================================================
# Lambda Context Mock
# ============================================================================

@pytest.fixture
def lambda_context():
    """Mock AWS Lambda context object."""
    context = MagicMock()
    context.function_name = "test-function"
    context.function_version = "$LATEST"
    context.invoked_function_arn = "arn:aws:lambda:us-east-1:123456789012:function:test-function"
    context.memory_limit_in_mb = 512
    context.aws_request_id = str(uuid.uuid4())
    context.log_group_name = "/aws/lambda/test-function"
    context.log_stream_name = "2024/01/01/[$LATEST]abc123"
    context.get_remaining_time_in_millis.return_value = 300000  # 5 minutes
    return context


# ============================================================================
# PySpark Session Fixture (for ETL tests)
# ============================================================================

@pytest.fixture(scope="session")
def spark_session():
    """Local PySpark session for ETL unit tests."""
    try:
        from pyspark.sql import SparkSession

        spark = (
            SparkSession.builder
            .master("local[2]")
            .appName("verticalbroker-test")
            .config("spark.sql.shuffle.partitions", "2")
            .config("spark.default.parallelism", "2")
            .config("spark.sql.warehouse.dir", "/tmp/spark-warehouse-test")
            .config("spark.driver.bindAddress", "127.0.0.1")
            .config("spark.ui.enabled", "false")
            .getOrCreate()
        )
        yield spark
        spark.stop()
    except ImportError:
        pytest.skip("PySpark not available")


# ============================================================================
# Test Data Factories
# ============================================================================

@pytest.fixture
def make_trade_event():
    """Factory for creating trade events with defaults."""
    def _factory(**overrides):
        defaults = {
            "order_id": str(uuid.uuid4()),
            "client_id": "client-001",
            "account_id": "account-001",
            "instrument_id": "AAPL",
            "side": "BUY",
            "quantity": Decimal("100"),
            "price": Decimal("185.50"),
            "executed_at": datetime.now(UTC).isoformat(),
            "correlation_id": str(uuid.uuid4()),
        }
        defaults.update(overrides)
        return defaults
    return _factory


@pytest.fixture
def make_market_data_record():
    """Factory for creating market data records."""
    def _factory(**overrides):
        defaults = {
            "source_id": "bloomberg-feed-1",
            "instrument_id": "AAPL",
            "timestamp": datetime.now(UTC).isoformat(),
            "event_type": "TRADE",
            "price": 185.50,
            "volume": 1000,
            "exchange": "NYSE",
            "schema_version": "1.0",
        }
        defaults.update(overrides)
        return defaults
    return _factory


@pytest.fixture
def make_order_request():
    """Factory for creating order requests."""
    def _factory(**overrides):
        defaults = {
            "instrument_id": "AAPL",
            "side": "BUY",
            "quantity": "100",
            "price": "185.50",
            "order_type": "LIMIT",
            "time_in_force": "GTC",
            "client_id": "client-001",
            "account_id": "account-001",
        }
        defaults.update(overrides)
        return defaults
    return _factory
