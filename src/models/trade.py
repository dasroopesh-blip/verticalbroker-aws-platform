"""Trade lifecycle and client profile data models.

Defines typed dataclass models for trading domain entities:
- TradeEvent: Canonical trade event flowing through the platform
- OrderRequest: Incoming order from trading applications
- OrderResponse: Order execution response
- ClientProfile: Client profile for portfolio and advisory services
- CustomerProfile: Input features for RL-based advisory model
- AdvisoryRecommendation: Output from RL advisory model

Requirements: 7.3 - Lambda Layers for shared data validation schemas
             12.1 - Advisory Agent customer profile inputs
"""

from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal
from typing import Dict, List, Optional


@dataclass
class TradeEvent:
    """Canonical trade event flowing through the platform.

    Published to EventBridge on trade execution, consumed by Wallet Service,
    compliance logging, and analytics pipelines.
    """

    # Identifiers
    trade_id: str  # UUID
    order_id: str  # Parent order UUID
    client_id: str
    account_id: str

    # Instrument
    instrument_id: str  # ISIN/CUSIP
    instrument_type: str  # EQUITY | BOND | OPTION | ETF | FUTURES

    # Execution details
    side: str  # BUY | SELL
    quantity: Decimal
    executed_price: Decimal
    total_value: Decimal  # quantity * price
    fees: Decimal
    net_value: Decimal  # total_value +/- fees

    # Timing
    order_timestamp: datetime
    execution_timestamp: datetime
    settlement_date: str  # T+1 or T+2

    # Routing
    venue: str  # Exchange or dark pool
    execution_type: str  # MARKET | LIMIT | STOP

    # Compliance
    compliance_flags: List[str] = field(default_factory=list)
    regulatory_report_id: Optional[str] = None


@dataclass
class OrderRequest:
    """Incoming order request from trading applications.

    Submitted through API Gateway POST /v1/orders endpoint.
    Validated for margin, position limits, and market hours.
    """

    client_id: str
    account_id: str
    instrument_id: str  # ISIN/CUSIP
    order_type: str  # MARKET | LIMIT | STOP | STOP_LIMIT
    side: str  # BUY | SELL
    quantity: Decimal
    time_in_force: str  # DAY | GTC | IOC | FOK
    idempotency_key: str  # Client-provided dedup key

    # Optional price fields (required for LIMIT/STOP orders)
    limit_price: Optional[Decimal] = None
    stop_price: Optional[Decimal] = None


@dataclass
class OrderResponse:
    """Order execution response returned to the client.

    Includes execution details or rejection reason.
    """

    order_id: str  # Platform-generated UUID
    status: str  # ACCEPTED | REJECTED | PENDING
    timestamp: datetime

    # Filled on execution
    executed_price: Optional[Decimal] = None
    executed_quantity: Optional[Decimal] = None

    # Filled on rejection
    rejection_reason: Optional[str] = None


@dataclass
class ClientProfile:
    """Client profile for advisory and portfolio services.

    Comprehensive client information including demographics, financials,
    investment preferences, and compliance status.
    """

    # Identifiers
    client_id: str

    # Demographics
    name: str
    age: int
    tax_filing_status: str  # SINGLE | MARRIED_JOINT | MARRIED_SEPARATE | HEAD_OF_HOUSEHOLD
    state_of_residence: str

    # Financial
    annual_income: Decimal
    total_debt: Decimal
    household_income: Decimal
    net_worth: Decimal

    # Investment profile
    risk_profile: str  # CONSERVATIVE | MODERATE | AGGRESSIVE | VERY_AGGRESSIVE
    investment_strategies: List[str]  # GROWTH | VALUE | INCOME | INDEX
    investment_horizon_years: int
    experience_level: str  # NOVICE | INTERMEDIATE | ADVANCED | EXPERT

    # Account relationship
    account_ids: List[str] = field(default_factory=list)
    advisor_id: Optional[str] = None
    service_tier: str = "SELF_SERVICE"  # FULL_SERVICE | SELF_SERVICE | AUTOMATED

    # Compliance
    kyc_status: str = "PENDING"  # VERIFIED | PENDING | FLAGGED
    accredited_investor: bool = False
    pep_status: bool = False  # Politically Exposed Person
    last_review_date: Optional[datetime] = None


@dataclass
class CustomerProfile:
    """Input features for RL-based advisory model.

    Subset of ClientProfile focused on features needed by the
    reinforcement learning model for portfolio allocation.

    Requirements: 12.1 - Advisory Agent accepts customer profile inputs
    """

    age: int
    tax_filing_status: str  # SINGLE | MARRIED_JOINT | MARRIED_SEPARATE | HEAD_OF_HOUSEHOLD
    annual_income: Decimal
    total_debt: Decimal
    household_income: Decimal
    risk_profile: str  # CONSERVATIVE | MODERATE | AGGRESSIVE | VERY_AGGRESSIVE
    investment_strategies: List[str]  # GROWTH | VALUE | INCOME | INDEX
    investment_horizon_years: int
    existing_allocations: Dict[str, Decimal] = field(default_factory=dict)

    def to_features(self) -> Dict[str, any]:
        """Convert profile to feature vector for SageMaker inference.

        Returns:
            Dictionary of features suitable for model input.
        """
        return {
            "age": self.age,
            "tax_filing_status": self.tax_filing_status,
            "annual_income": float(self.annual_income),
            "total_debt": float(self.total_debt),
            "household_income": float(self.household_income),
            "risk_profile": self.risk_profile,
            "investment_strategies": self.investment_strategies,
            "investment_horizon_years": self.investment_horizon_years,
            "existing_allocations": {
                k: float(v) for k, v in self.existing_allocations.items()
            },
        }


@dataclass
class AdvisoryRecommendation:
    """Output from RL advisory model.

    Includes portfolio allocation percentages, confidence score,
    and governance flags for FINRA compliance.

    Requirements: 12.5 - Log all recommendations for FINRA audit
                 12.6 - Flag low-confidence recommendations for human review
    """

    recommendation_id: str  # UUID
    model_version: str
    allocations: Dict[str, Decimal]  # asset_class -> percentage
    confidence_score: float  # 0.0 - 1.0
    explanation: str
    requires_human_review: bool = False  # True if confidence < 0.7
    uncertainty_factors: List[str] = field(default_factory=list)


__all__ = [
    "TradeEvent",
    "OrderRequest",
    "OrderResponse",
    "ClientProfile",
    "CustomerProfile",
    "AdvisoryRecommendation",
]
