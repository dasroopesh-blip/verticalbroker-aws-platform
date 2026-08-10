"""Advisory Agent Lambda Service.

Provides ML-powered automated investment advisory using SageMaker Reinforcement
Learning inference. Implements governance rules (human review for low-confidence
predictions) and FINRA compliance logging to the Regulatory Store.

Routes:
    POST /v1/advisory - Generate portfolio allocation recommendation

Configuration:
    Reserved concurrency: 500
    Provisioned concurrency: 100

Requirements: 12.1, 12.4, 12.5, 12.6
"""

from src.services.advisory_agent.governance import (
    GovernanceEngine,
    RegulatoryStore,
    GovernanceResult,
)
from src.services.advisory_agent.handler import (
    AdvisoryAgentService,
    CustomerProfile,
    AdvisoryRecommendation,
    RiskMetrics,
)

__all__ = [
    "AdvisoryAgentService",
    "CustomerProfile",
    "AdvisoryRecommendation",
    "RiskMetrics",
    "GovernanceEngine",
    "RegulatoryStore",
    "GovernanceResult",
]
