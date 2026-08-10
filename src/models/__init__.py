"""Data models for the VerticalBroker platform.

Provides typed dataclass definitions for all domain entities:
- market_data: Bronze/Silver/Gold layer market data schemas
- trade: Trade lifecycle and client profile models
- events: EventBridge event schemas

All models use Python 3.12 dataclasses with Decimal for financial
precision and datetime for timestamps.
"""

__all__ = [
    # Market data models
    "MarketDataRaw",
    "MarketDataSilver",
    "DailyTradeSummaryGold",
    # Trade models
    "TradeEvent",
    "OrderRequest",
    "OrderResponse",
    "ClientProfile",
    "CustomerProfile",
    "AdvisoryRecommendation",
    # Event models
    "BaseEvent",
    "DataIngestedEvent",
    "TradeExecutedEvent",
    "PipelineFailedEvent",
    "ComplianceAlertEvent",
    "AdvisoryGeneratedEvent",
]
