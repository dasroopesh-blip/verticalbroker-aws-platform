"""ML module for VerticalBroker Advisory Agent.

Provides SageMaker RL training pipeline and model governance capabilities
for the automated investment advisory service.

Components:
    - AdvisoryModelPipeline: End-to-end training pipeline (feature engineering,
      RL training with PPO, evaluation, and model registration)
    - ModelGovernance: Pre-deployment governance checks including bias detection,
      fairness validation, explainability, and approval workflow

Requirements:
    12.2 - SageMaker RL training on Gold Layer historical data
    12.3 - Model versioning with metadata
    12.8 - Model governance (bias, fairness, explainability)
"""

from src.ml.training_pipeline import AdvisoryModelPipeline
from src.ml.model_governance import ModelGovernance

__all__ = [
    "AdvisoryModelPipeline",
    "ModelGovernance",
]
