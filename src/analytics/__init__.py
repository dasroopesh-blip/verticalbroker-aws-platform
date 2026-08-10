"""Analytics module for VerticalBroker platform.

Provides Neptune graph database models and fraud detection query templates.
"""

from src.analytics.graph_model import (
    ClientVertex,
    AccountVertex,
    InstrumentVertex,
    TransactionEdge,
    FRAUD_QUERIES,
)

__all__ = [
    "ClientVertex",
    "AccountVertex",
    "InstrumentVertex",
    "TransactionEdge",
    "FRAUD_QUERIES",
]
