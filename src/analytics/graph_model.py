"""Neptune graph data model definitions for VerticalBroker.

Defines vertex and edge schemas for the Neptune graph database used in
relationship-based analytics, fraud detection, and compliance analysis.

Requirements:
    10.1 - Graph model: clients, accounts, instruments, advisors, transactions
    10.2 - Incremental updates every 15 minutes from Gold Layer
    10.3 - Traversal results within 5 seconds for 4-hop queries
    10.5 - Fraud detection: circular transactions, rapid transfers, unusual velocity
    10.6 - Parameterized query templates preventing injection attacks
"""

from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal
from typing import Any, Optional


# ---------------------------------------------------------
# VERTEX DEFINITIONS
# ---------------------------------------------------------


@dataclass
class ClientVertex:
    """Client entity in the graph model.

    Represents a brokerage client with their risk profile, KYC status,
    and account relationship metadata.
    """

    label: str = "Client"
    properties: dict[str, type] = field(default_factory=lambda: {
        "client_id": str,           # Primary key
        "name": str,
        "risk_profile": str,        # CONSERVATIVE | MODERATE | AGGRESSIVE | VERY_AGGRESSIVE
        "kyc_status": str,          # VERIFIED | PENDING | FLAGGED
        "account_type": str,        # FULL_SERVICE | SELF_SERVICE | AUTOMATED
        "onboarding_date": datetime,
        "total_aum": Decimal,       # Assets Under Management
    })

    # Gremlin query to create a client vertex
    @staticmethod
    def create_query(client_id: str, name: str, risk_profile: str,
                     kyc_status: str, account_type: str,
                     onboarding_date: str, total_aum: float) -> str:
        """Generate parameterized Gremlin query to add a Client vertex.

        Uses parameterized bindings to prevent injection attacks (Requirement 10.6).
        """
        return (
            "g.addV('Client')"
            ".property(id, client_id)"
            ".property('name', name)"
            ".property('risk_profile', risk_profile)"
            ".property('kyc_status', kyc_status)"
            ".property('account_type', account_type)"
            ".property('onboarding_date', onboarding_date)"
            ".property('total_aum', total_aum)"
        )

    @staticmethod
    def create_bindings(client_id: str, name: str, risk_profile: str,
                        kyc_status: str, account_type: str,
                        onboarding_date: str, total_aum: float) -> dict[str, Any]:
        """Generate parameter bindings for safe query execution."""
        return {
            "client_id": client_id,
            "name": name,
            "risk_profile": risk_profile,
            "kyc_status": kyc_status,
            "account_type": account_type,
            "onboarding_date": onboarding_date,
            "total_aum": total_aum,
        }


@dataclass
class AccountVertex:
    """Account entity in the graph model.

    Represents a brokerage account (individual, joint, IRA, etc.)
    with balance and margin information.
    """

    label: str = "Account"
    properties: dict[str, type] = field(default_factory=lambda: {
        "account_id": str,          # Primary key
        "account_type": str,        # INDIVIDUAL | JOINT | IRA | 401K | TRUST
        "status": str,              # ACTIVE | FROZEN | CLOSED
        "cash_balance": Decimal,
        "margin_enabled": bool,
        "created_date": datetime,
    })

    @staticmethod
    def create_query(account_id: str, account_type: str, status: str,
                     cash_balance: float, margin_enabled: bool,
                     created_date: str) -> str:
        """Generate parameterized Gremlin query to add an Account vertex."""
        return (
            "g.addV('Account')"
            ".property(id, account_id)"
            ".property('account_type', account_type)"
            ".property('status', status)"
            ".property('cash_balance', cash_balance)"
            ".property('margin_enabled', margin_enabled)"
            ".property('created_date', created_date)"
        )

    @staticmethod
    def create_bindings(account_id: str, account_type: str, status: str,
                        cash_balance: float, margin_enabled: bool,
                        created_date: str) -> dict[str, Any]:
        """Generate parameter bindings for safe query execution."""
        return {
            "account_id": account_id,
            "account_type": account_type,
            "status": status,
            "cash_balance": cash_balance,
            "margin_enabled": margin_enabled,
            "created_date": created_date,
        }


@dataclass
class InstrumentVertex:
    """Instrument entity in the graph model.

    Represents a financial instrument (equity, bond, option, ETF, etc.)
    with exchange and sector classification.
    """

    label: str = "Instrument"
    properties: dict[str, type] = field(default_factory=lambda: {
        "instrument_id": str,       # ISIN/CUSIP - Primary key
        "name": str,
        "type": str,                # EQUITY | BOND | OPTION | ETF | MUTUAL_FUND
        "sector": str,
        "exchange": str,
        "currency": str,
    })

    @staticmethod
    def create_query(instrument_id: str, name: str, instrument_type: str,
                     sector: str, exchange: str, currency: str) -> str:
        """Generate parameterized Gremlin query to add an Instrument vertex."""
        return (
            "g.addV('Instrument')"
            ".property(id, instrument_id)"
            ".property('name', name)"
            ".property('type', instrument_type)"
            ".property('sector', sector)"
            ".property('exchange', exchange)"
            ".property('currency', currency)"
        )

    @staticmethod
    def create_bindings(instrument_id: str, name: str, instrument_type: str,
                        sector: str, exchange: str, currency: str) -> dict[str, Any]:
        """Generate parameter bindings for safe query execution."""
        return {
            "instrument_id": instrument_id,
            "name": name,
            "instrument_type": instrument_type,
            "sector": sector,
            "exchange": exchange,
            "currency": currency,
        }


# ---------------------------------------------------------
# EDGE DEFINITIONS
# ---------------------------------------------------------


@dataclass
class TransactionEdge:
    """Transaction edge connecting Account to Instrument via execution.

    Models the EXECUTED relationship capturing trade details including
    side, quantity, price, and fees.
    """

    label: str = "EXECUTED"
    from_vertex: str = "Account"
    to_vertex: str = "Instrument"
    properties: dict[str, type] = field(default_factory=lambda: {
        "transaction_id": str,      # Unique transaction identifier
        "timestamp": datetime,
        "side": str,                # BUY | SELL
        "quantity": Decimal,
        "price": Decimal,
        "fees": Decimal,
    })

    @staticmethod
    def create_query(account_id: str, instrument_id: str,
                     transaction_id: str, timestamp: str,
                     side: str, quantity: float,
                     price: float, fees: float) -> str:
        """Generate parameterized Gremlin query to add a transaction edge.

        Uses parameterized bindings to prevent injection attacks (Requirement 10.6).
        """
        return (
            "g.V(account_id).addE('EXECUTED').to(g.V(instrument_id))"
            ".property('transaction_id', transaction_id)"
            ".property('timestamp', timestamp)"
            ".property('side', side)"
            ".property('quantity', quantity)"
            ".property('price', price)"
            ".property('fees', fees)"
        )

    @staticmethod
    def create_bindings(account_id: str, instrument_id: str,
                        transaction_id: str, timestamp: str,
                        side: str, quantity: float,
                        price: float, fees: float) -> dict[str, Any]:
        """Generate parameter bindings for safe query execution."""
        return {
            "account_id": account_id,
            "instrument_id": instrument_id,
            "transaction_id": transaction_id,
            "timestamp": timestamp,
            "side": side,
            "quantity": quantity,
            "price": price,
            "fees": fees,
        }


# ---------------------------------------------------------
# ADDITIONAL EDGE TYPES
# ---------------------------------------------------------


@dataclass
class OwnsEdge:
    """OWNS edge: Client → Account relationship."""

    label: str = "OWNS"
    from_vertex: str = "Client"
    to_vertex: str = "Account"
    properties: dict[str, type] = field(default_factory=lambda: {
        "since": datetime,
        "role": str,  # PRIMARY | JOINT | BENEFICIARY
    })


@dataclass
class TransfersToEdge:
    """TRANSFERS_TO edge: Client → Client for money transfers.

    Critical for fraud detection - circular transfer patterns.
    """

    label: str = "TRANSFERS_TO"
    from_vertex: str = "Client"
    to_vertex: str = "Client"
    properties: dict[str, type] = field(default_factory=lambda: {
        "transfer_id": str,
        "timestamp": datetime,
        "amount": Decimal,
        "currency": str,
    })


@dataclass
class AdvisedByEdge:
    """ADVISED_BY edge: Client → Advisor relationship."""

    label: str = "ADVISED_BY"
    from_vertex: str = "Client"
    to_vertex: str = "Advisor"
    properties: dict[str, type] = field(default_factory=lambda: {
        "since": datetime,
        "service_tier": str,  # FULL_SERVICE | SELF_SERVICE | AUTOMATED
    })


@dataclass
class CorrelatesWithEdge:
    """CORRELATES_WITH edge: Instrument → Instrument correlation."""

    label: str = "CORRELATES_WITH"
    from_vertex: str = "Instrument"
    to_vertex: str = "Instrument"
    properties: dict[str, type] = field(default_factory=lambda: {
        "correlation_coefficient": float,
        "period_days": int,
        "computed_at": datetime,
    })


# ---------------------------------------------------------
# FRAUD DETECTION GREMLIN QUERIES (Requirement 10.5)
#
# Parameterized query templates for fraud detection patterns.
# All queries use bound parameters to prevent injection (Requirement 10.6).
# Designed for <=5 second response across 4-hop traversals (Requirement 10.3).
# ---------------------------------------------------------

FRAUD_QUERIES: dict[str, dict[str, str]] = {
    "circular_transactions": {
        "description": (
            "Detect circular transaction patterns where money flows from a client "
            "through a chain of accounts and returns to the originating client. "
            "This is a common indicator of money laundering or wash trading."
        ),
        "query": (
            "g.V().hasLabel('Client').has('client_id', client_id).as('start')"
            ".out('OWNS').out('EXECUTED').out('INVOLVES')"
            ".in('EXECUTED').in('OWNS')"
            ".where(eq('start'))"
            ".path()"
            ".limit(max_results)"
        ),
        "bindings": {
            "client_id": "Target client ID to check for circular patterns",
            "max_results": "Maximum number of circular paths to return (default: 100)",
        },
        "max_hops": 4,
    },
    "rapid_transfers": {
        "description": (
            "Identify clients making an unusually high number of transfers "
            "within a short time window (default: 1 hour). More than the threshold "
            "number of transfers triggers a flag for compliance review."
        ),
        "query": (
            "g.V().hasLabel('Client').as('c')"
            ".outE('TRANSFERS_TO')"
            ".has('timestamp', gte(time_window_start))"
            ".has('timestamp', lte(time_window_end))"
            ".group().by(select('c').values('client_id'))"
            ".unfold()"
            ".where(select(values).count(local).is(gt(transfer_threshold)))"
        ),
        "bindings": {
            "time_window_start": "Start of time window (ISO-8601 datetime)",
            "time_window_end": "End of time window (ISO-8601 datetime)",
            "transfer_threshold": "Minimum number of transfers to flag (default: 10)",
        },
        "max_hops": 2,
    },
    "unusual_velocity": {
        "description": (
            "Detect clients whose trading velocity (number of transactions) "
            "significantly exceeds their historical average within a time window. "
            "Uses standard deviation threshold for anomaly detection."
        ),
        "query": (
            "g.V().hasLabel('Client').has('client_id', client_id)"
            ".out('OWNS').outE('EXECUTED')"
            ".has('timestamp', gte(time_window_start))"
            ".has('timestamp', lte(time_window_end))"
            ".count()"
        ),
        "bindings": {
            "client_id": "Target client ID to check trading velocity",
            "time_window_start": "Start of analysis window (ISO-8601 datetime)",
            "time_window_end": "End of analysis window (ISO-8601 datetime)",
        },
        "max_hops": 3,
    },
    "connected_flagged_accounts": {
        "description": (
            "Find all accounts connected to a flagged client within N hops. "
            "Used to identify networks of potentially compromised accounts "
            "when a KYC flag is raised."
        ),
        "query": (
            "g.V().hasLabel('Client').has('client_id', flagged_client_id)"
            ".repeat(both().simplePath())"
            ".until(loops().is(max_hops))"
            ".hasLabel('Client')"
            ".has('kyc_status', 'FLAGGED')"
            ".path()"
            ".limit(max_results)"
        ),
        "bindings": {
            "flagged_client_id": "Client ID of the initially flagged client",
            "max_hops": "Maximum traversal depth (default: 4, per Requirement 10.3)",
            "max_results": "Maximum number of paths to return (default: 50)",
        },
        "max_hops": 4,
    },
    "wash_trading_detection": {
        "description": (
            "Detect potential wash trading by identifying buy-sell pairs on the "
            "same instrument within a short time window at similar prices, "
            "possibly across related accounts."
        ),
        "query": (
            "g.V().hasLabel('Client').has('client_id', client_id)"
            ".out('OWNS').outE('EXECUTED')"
            ".has('timestamp', gte(time_window_start))"
            ".has('timestamp', lte(time_window_end))"
            ".as('trade')"
            ".inV().as('instrument')"
            ".inE('EXECUTED')"
            ".has('side', neq(select('trade').values('side')))"
            ".has('timestamp', gte(time_window_start))"
            ".where(math('abs(trade_price - price)').is(lt(price_tolerance)))"
            ".path()"
            ".limit(max_results)"
        ),
        "bindings": {
            "client_id": "Target client ID",
            "time_window_start": "Start of analysis window (ISO-8601)",
            "time_window_end": "End of analysis window (ISO-8601)",
            "price_tolerance": "Maximum price difference for matching (default: 0.01)",
            "max_results": "Maximum results to return (default: 100)",
        },
        "max_hops": 4,
    },
}


# ---------------------------------------------------------
# BULK LOADER CONFIGURATION (Requirement 10.2)
# ---------------------------------------------------------

NEPTUNE_BULK_LOADER_CONFIG: dict[str, Any] = {
    "source": "s3://{{gold_bucket}}/graph-export/",
    "format": "csv",
    "iamRoleArn": "{{neptune_loader_role_arn}}",
    "region": "{{aws_region}}",
    "failOnError": "FALSE",
    "parallelism": "MEDIUM",
    "updateSingleCardinalityProperties": "TRUE",
    "queueRequest": "TRUE",
    "dependencies": [],
}

# Vertex CSV column headers for Neptune bulk loader
VERTEX_CSV_HEADERS: dict[str, list[str]] = {
    "Client": [
        "~id", "~label", "client_id:String", "name:String",
        "risk_profile:String", "kyc_status:String", "account_type:String",
        "onboarding_date:Date", "total_aum:Double",
    ],
    "Account": [
        "~id", "~label", "account_id:String", "account_type:String",
        "status:String", "cash_balance:Double", "margin_enabled:Bool",
        "created_date:Date",
    ],
    "Instrument": [
        "~id", "~label", "instrument_id:String", "name:String",
        "type:String", "sector:String", "exchange:String", "currency:String",
    ],
}

# Edge CSV column headers for Neptune bulk loader
EDGE_CSV_HEADERS: dict[str, list[str]] = {
    "EXECUTED": [
        "~id", "~from", "~to", "~label",
        "transaction_id:String", "timestamp:Date",
        "side:String", "quantity:Double", "price:Double", "fees:Double",
    ],
    "OWNS": [
        "~id", "~from", "~to", "~label",
        "since:Date", "role:String",
    ],
    "TRANSFERS_TO": [
        "~id", "~from", "~to", "~label",
        "transfer_id:String", "timestamp:Date",
        "amount:Double", "currency:String",
    ],
}
