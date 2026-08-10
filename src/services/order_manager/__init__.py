"""Order Manager Service.

Handles order lifecycle for VerticalBroker's trading platform:
- Idempotent order submission via DynamoDB persistence layer (24h TTL)
- Pre-trade validation: margin checks, position limits, market hours
- Trade execution with transactional outbox pattern for event emission
- REST API routes: POST /v1/orders, GET /v1/orders/{id}

Lambda Configuration:
    Reserved Concurrency: 1000
    Provisioned Concurrency: 200
    Runtime: Python 3.12
    Powertools: Logger, Tracer, Metrics, APIGatewayHttpResolver

Requirements: 7.1, 7.2, 7.5, 8.4
"""
