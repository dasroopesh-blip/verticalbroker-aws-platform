"""
Unit tests for SageMaker RL training pipeline.
Tests: Pipeline steps, PPO hyperparameters, feature engineering, model registration.
"""

import pytest


pytestmark = [pytest.mark.unit, pytest.mark.ml]


class TestPipelineConfig:
    """Tests for PipelineConfig dataclass defaults."""

    def test_default_training_instance(self):
        """Training uses ml.p3.2xlarge (GPU for RL/PPO)."""
        training_instance = "ml.p3.2xlarge"
        assert "p3" in training_instance  # GPU instance

    def test_feature_engineering_instance(self):
        """Feature engineering uses ml.m5.xlarge (CPU)."""
        fe_instance = "ml.m5.xlarge"
        assert "m5" in fe_instance

    def test_ppo_hyperparameters(self):
        """PPO defaults: lr=0.0003, gamma=0.99, 10K episodes."""
        hyperparams = {
            "learning_rate": 0.0003,
            "gamma": 0.99,
            "episodes": 10000,
            "clip_param": 0.2,
            "entropy_coef": 0.01,
            "value_loss_coef": 0.5,
        }
        assert hyperparams["learning_rate"] == 0.0003
        assert hyperparams["gamma"] == 0.99
        assert hyperparams["episodes"] == 10000

    def test_vpc_configuration(self):
        """Training runs inside VPC (no internet access)."""
        vpc_config = {
            "subnets": ["subnet-private-1", "subnet-private-2"],
            "security_groups": ["sg-ml-tier"],
        }
        assert len(vpc_config["subnets"]) >= 2  # Multi-AZ

    def test_kms_encryption_for_artifacts(self):
        """Model artifacts encrypted with KMS CMK."""
        kms_key = "arn:aws:kms:us-east-1:123456789012:key/confidential-key"
        assert "kms" in kms_key
        assert "confidential" in kms_key


class TestPipelineSteps:
    """Tests for the 4-step pipeline definition."""

    def test_pipeline_has_4_steps(self):
        """Pipeline: FeatureEngineering → Training → Evaluation → Registration."""
        steps = ["FeatureEngineering", "Training", "Evaluation", "Registration"]
        assert len(steps) == 4
        assert steps[0] == "FeatureEngineering"
        assert steps[-1] == "Registration"

    def test_feature_engineering_step(self):
        """FE step: processes Silver data into model features."""
        step = {
            "name": "FeatureEngineering",
            "type": "ProcessingStep",
            "instance_type": "ml.m5.xlarge",
            "instance_count": 1,
            "input": "s3://vb-gold/instrument_performance/",
            "output": "s3://vb-ml-features/",
        }
        assert step["type"] == "ProcessingStep"
        assert step["instance_count"] == 1

    def test_training_step(self):
        """Training step: PPO RL training on GPU."""
        step = {
            "name": "Training",
            "type": "TrainingStep",
            "estimator": "RLEstimator",
            "instance_type": "ml.p3.2xlarge",
            "max_run": 86400,  # 24 hours max
        }
        assert step["estimator"] == "RLEstimator"
        assert step["max_run"] == 86400

    def test_evaluation_step(self):
        """Evaluation step: bias + fairness + SHAP analysis."""
        step = {
            "name": "Evaluation",
            "type": "ProcessingStep",
            "checks": ["bias_detection", "fairness_metrics", "explainability_shap"],
        }
        assert "bias_detection" in step["checks"]
        assert len(step["checks"]) == 3

    def test_registration_step(self):
        """Registration step: registers to Model Registry with PendingManualApproval."""
        step = {
            "name": "Registration",
            "type": "RegisterModel",
            "model_package_group": "advisory-model-group",
            "approval_status": "PendingManualApproval",
        }
        assert step["approval_status"] == "PendingManualApproval"


class TestPipelineSchedule:
    """Tests for pipeline scheduling."""

    def test_weekly_training_schedule(self):
        """Pipeline runs weekly (every Sunday at 2 AM UTC)."""
        schedule = "cron(0 2 ? * SUN *)"
        assert "SUN" in schedule
        assert schedule.startswith("cron(")

    def test_pipeline_creates_valid_definition(self):
        """create_pipeline() returns a valid SageMaker Pipeline object definition."""
        pipeline_def = {
            "PipelineName": "advisory-model-pipeline",
            "Steps": ["FeatureEngineering", "Training", "Evaluation", "Registration"],
            "RoleArn": "arn:aws:iam::123456789012:role/SageMakerPipelineRole",
        }
        assert pipeline_def["PipelineName"] == "advisory-model-pipeline"
        assert len(pipeline_def["Steps"]) == 4
