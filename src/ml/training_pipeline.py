"""SageMaker RL Training Pipeline for Advisory Agent.

Defines the end-to-end ML pipeline: feature engineering → RL training (PPO) →
evaluation → model registration with governance metadata.

Requirements:
    12.2 - SageMaker RL training on Gold Layer historical data
    12.3 - Model versioning with metadata (dataset version, hyperparameters, metrics, approval)
    12.8 - Model governance review (bias, fairness, explainability) before deployment
"""

import os
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional

import sagemaker
from sagemaker.processing import ProcessingInput, ProcessingOutput, ScriptProcessor
from sagemaker.rl import RLEstimator
from sagemaker.workflow.parameters import ParameterString
from sagemaker.workflow.pipeline import Pipeline
from sagemaker.workflow.steps import ProcessingStep, TrainingStep
from sagemaker.workflow.step_collections import RegisterModel


@dataclass
class PipelineConfig:
    """Configuration for the advisory model training pipeline."""

    role: str
    region: str = "us-east-1"
    pipeline_name: str = "verticalbroker-advisory-training"
    model_package_group: str = "verticalbroker-advisory-models"

    # S3 paths
    gold_layer_uri: str = ""
    model_artifacts_uri: str = ""
    pipeline_artifacts_uri: str = ""

    # Feature engineering
    feature_engineering_instance_type: str = "ml.m5.xlarge"
    feature_engineering_instance_count: int = 1
    feature_engineering_volume_size_gb: int = 50

    # Training hyperparameters (PPO)
    training_instance_type: str = "ml.p3.2xlarge"
    training_instance_count: int = 1
    training_volume_size_gb: int = 100
    training_max_runtime_seconds: int = 86400
    learning_rate: float = 0.0003
    gamma: float = 0.99
    num_episodes: int = 10000
    batch_size: int = 256

    # Evaluation
    evaluation_instance_type: str = "ml.m5.xlarge"
    evaluation_instance_count: int = 1

    # VPC configuration
    subnets: list[str] = field(default_factory=list)
    security_group_ids: list[str] = field(default_factory=list)

    # Encryption
    kms_key_id: Optional[str] = None

    # Container images
    feature_engineering_image_uri: str = ""
    training_image_uri: str = ""
    evaluation_image_uri: str = ""
    inference_image_uri: str = ""


class AdvisoryModelPipeline:
    """End-to-end ML pipeline: feature engineering → train → evaluate → register.

    Implements the full training workflow for the RL-based advisory agent,
    including feature extraction from the Gold layer, PPO training,
    model evaluation with bias/fairness checks, and model registration
    with governance metadata in SageMaker Model Registry.

    Requirements:
        12.2 - SageMaker RL training on historical Gold Layer data
        12.3 - Model versioning with metadata
        12.8 - Governance review before deployment
    """

    def __init__(self, config: PipelineConfig):
        """Initialize pipeline with configuration.

        Args:
            config: PipelineConfig containing all pipeline parameters.
        """
        self.config = config
        self.session = sagemaker.Session()
        self.role = config.role
        self.model_package_group = config.model_package_group

        # Pipeline parameters (overridable at execution time)
        self.training_data_uri = ParameterString(
            name="TrainingDataUri",
            default_value=config.gold_layer_uri,
        )
        self.model_approval_status = ParameterString(
            name="ModelApprovalStatus",
            default_value="PendingManualApproval",
        )
        self.dataset_version = ParameterString(
            name="DatasetVersion",
            default_value="latest",
        )

    def create_feature_engineering_step(self) -> ProcessingStep:
        """Extract and transform features from Gold layer historical data.

        Reads client outcome data from the Gold layer S3 location,
        performs feature extraction (customer profile attributes,
        historical portfolio performance, market conditions), and
        produces train/test splits for RL training.

        Returns:
            ProcessingStep configured for feature engineering on ml.m5.xlarge.
        """
        processor = ScriptProcessor(
            role=self.role,
            image_uri=self.config.feature_engineering_image_uri,
            instance_count=self.config.feature_engineering_instance_count,
            instance_type=self.config.feature_engineering_instance_type,
            volume_size_in_gb=self.config.feature_engineering_volume_size_gb,
            volume_kms_key=self.config.kms_key_id,
            network_config=self._get_network_config(),
            sagemaker_session=self.session,
            command=["python3"],
        )

        step = ProcessingStep(
            name="FeatureEngineering",
            processor=processor,
            inputs=[
                ProcessingInput(
                    source=self.training_data_uri,
                    destination="/opt/ml/processing/input",
                    input_name="gold-layer-data",
                ),
            ],
            outputs=[
                ProcessingOutput(
                    output_name="features",
                    source="/opt/ml/processing/output/features",
                    destination=f"{self.config.pipeline_artifacts_uri}/features/",
                ),
                ProcessingOutput(
                    output_name="train-test-split",
                    source="/opt/ml/processing/output/split",
                    destination=f"{self.config.pipeline_artifacts_uri}/train-test-split/",
                ),
            ],
            code="feature_engineering.py",
        )
        return step

    def create_training_step(self) -> TrainingStep:
        """Train RL model using PPO algorithm on GPU instances.

        Configures an RLEstimator with Proximal Policy Optimization (PPO)
        hyperparameters optimized for the advisory use case:
        - Learning rate: 0.0003 (stable convergence)
        - Gamma: 0.99 (long-term reward focus for investment horizons)
        - Episodes: 10000 (sufficient exploration)
        - Batch size: 256 (GPU memory efficient)

        Returns:
            TrainingStep configured for RL training on ml.p3.2xlarge (GPU).
        """
        estimator = RLEstimator(
            entry_point="train_advisory.py",
            source_dir="src/ml/rl_training/",
            role=self.role,
            framework="ray",
            framework_version="2.6.0",
            instance_type=self.config.training_instance_type,
            instance_count=self.config.training_instance_count,
            volume_size=self.config.training_volume_size_gb,
            volume_kms_key=self.config.kms_key_id,
            max_run=self.config.training_max_runtime_seconds,
            output_path=f"{self.config.pipeline_artifacts_uri}/model-artifacts/",
            output_kms_key=self.config.kms_key_id,
            subnets=self.config.subnets or None,
            security_group_ids=self.config.security_group_ids or None,
            hyperparameters={
                "algorithm": "PPO",
                "learning_rate": self.config.learning_rate,
                "gamma": self.config.gamma,
                "num_episodes": self.config.num_episodes,
                "batch_size": self.config.batch_size,
                "entropy_coeff": 0.01,
                "clip_param": 0.2,
                "num_sgd_iter": 10,
                "vf_loss_coeff": 0.5,
                "framework": "torch",
            },
            metric_definitions=[
                {"Name": "episode_reward_mean", "Regex": "episode_reward_mean: ([0-9\\.]+)"},
                {"Name": "episode_len_mean", "Regex": "episode_len_mean: ([0-9\\.]+)"},
                {"Name": "policy_loss", "Regex": "policy_loss: ([0-9\\.\\-]+)"},
                {"Name": "value_loss", "Regex": "vf_loss: ([0-9\\.]+)"},
                {"Name": "entropy", "Regex": "entropy: ([0-9\\.]+)"},
            ],
            sagemaker_session=self.session,
        )

        step = TrainingStep(
            name="Training",
            estimator=estimator,
            inputs={
                "train": sagemaker.inputs.TrainingInput(
                    s3_data=f"{self.config.pipeline_artifacts_uri}/features/",
                    content_type="application/x-parquet",
                ),
            },
        )
        return step

    def create_evaluation_step(self) -> ProcessingStep:
        """Evaluate model on performance, bias, and fairness metrics.

        Runs comprehensive model evaluation including:
        - Performance metrics (reward, Sharpe ratio, drawdown, portfolio returns)
        - Bias detection across demographic groups (age, income, filing status)
        - Fairness metrics ensuring equitable recommendations
        - Explainability via SHAP feature importance

        Returns:
            ProcessingStep configured for model evaluation on ml.m5.xlarge.
        """
        processor = ScriptProcessor(
            role=self.role,
            image_uri=self.config.evaluation_image_uri,
            instance_count=self.config.evaluation_instance_count,
            instance_type=self.config.evaluation_instance_type,
            volume_size_in_gb=self.config.feature_engineering_volume_size_gb,
            volume_kms_key=self.config.kms_key_id,
            network_config=self._get_network_config(),
            sagemaker_session=self.session,
            command=["python3"],
        )

        step = ProcessingStep(
            name="Evaluation",
            processor=processor,
            inputs=[
                ProcessingInput(
                    source=f"{self.config.pipeline_artifacts_uri}/model-artifacts/",
                    destination="/opt/ml/processing/input/model",
                    input_name="model-artifacts",
                ),
                ProcessingInput(
                    source=f"{self.config.pipeline_artifacts_uri}/train-test-split/",
                    destination="/opt/ml/processing/input/test",
                    input_name="test-data",
                ),
            ],
            outputs=[
                ProcessingOutput(
                    output_name="evaluation-report",
                    source="/opt/ml/processing/output/evaluation",
                    destination=f"{self.config.pipeline_artifacts_uri}/evaluation/",
                ),
                ProcessingOutput(
                    output_name="bias-report",
                    source="/opt/ml/processing/output/bias",
                    destination=f"{self.config.pipeline_artifacts_uri}/bias/",
                ),
                ProcessingOutput(
                    output_name="explainability-report",
                    source="/opt/ml/processing/output/explainability",
                    destination=f"{self.config.pipeline_artifacts_uri}/explainability/",
                ),
            ],
            code="evaluate_model.py",
        )
        return step

    def create_registration_step(self) -> RegisterModel:
        """Register model with governance metadata in SageMaker Model Registry.

        Registers the trained model with full provenance metadata including:
        - Training dataset version
        - Hyperparameters used
        - Performance metrics
        - Bias and fairness reports
        - Approval status (PendingManualApproval by default)

        The registered model enters the approval workflow where governance
        checks must pass before production deployment.

        Returns:
            RegisterModel step for the SageMaker Pipeline.
        """
        step = RegisterModel(
            name="Registration",
            model_data=f"{self.config.pipeline_artifacts_uri}/model-artifacts/model.tar.gz",
            content_types=["application/json"],
            response_types=["application/json"],
            inference_instances=[
                "ml.m5.xlarge",
                "ml.m5.2xlarge",
                "ml.c5.xlarge",
            ],
            transform_instances=["ml.m5.xlarge"],
            model_package_group_name=self.model_package_group,
            approval_status=self.model_approval_status,
            image_uri=self.config.inference_image_uri,
            customer_metadata_properties={
                "DatasetVersion": self.dataset_version.default_value,
                "Algorithm": "PPO",
                "Framework": "Ray-2.6.0",
                "LearningRate": str(self.config.learning_rate),
                "Gamma": str(self.config.gamma),
                "NumEpisodes": str(self.config.num_episodes),
                "BatchSize": str(self.config.batch_size),
                "TrainingInstance": self.config.training_instance_type,
                "PipelineName": self.config.pipeline_name,
                "TrainedAt": datetime.utcnow().isoformat(),
            },
            model_metrics={
                "ModelQuality": {
                    "Statistics": {
                        "ContentType": "application/json",
                        "S3Uri": f"{self.config.pipeline_artifacts_uri}/evaluation/metrics.json",
                    },
                },
                "Bias": {
                    "Report": {
                        "ContentType": "application/json",
                        "S3Uri": f"{self.config.pipeline_artifacts_uri}/bias/bias_report.json",
                    },
                },
                "Explainability": {
                    "Report": {
                        "ContentType": "application/json",
                        "S3Uri": f"{self.config.pipeline_artifacts_uri}/explainability/shap_report.json",
                    },
                },
            },
        )
        return step

    def create_pipeline(self) -> Pipeline:
        """Assemble the full training pipeline with all steps.

        Creates a SageMaker Pipeline with the following step sequence:
            1. FeatureEngineering → Extract features from Gold Layer
            2. Training → RLEstimator with PPO on ml.p3.2xlarge
            3. Evaluation → Performance, bias, fairness metrics
            4. Registration → Register with governance metadata

        Returns:
            Fully configured SageMaker Pipeline ready for execution.
        """
        feature_step = self.create_feature_engineering_step()
        training_step = self.create_training_step()
        evaluation_step = self.create_evaluation_step()
        registration_step = self.create_registration_step()

        # Define step dependencies
        training_step.add_depends_on([feature_step])
        evaluation_step.add_depends_on([training_step])
        registration_step.add_depends_on([evaluation_step])

        pipeline = Pipeline(
            name=self.config.pipeline_name,
            parameters=[
                self.training_data_uri,
                self.model_approval_status,
                self.dataset_version,
            ],
            steps=[
                feature_step,
                training_step,
                evaluation_step,
                registration_step,
            ],
            sagemaker_session=self.session,
        )
        return pipeline

    def _get_network_config(self) -> Optional[dict]:
        """Build network configuration for processing jobs.

        Returns:
            Network config dict if VPC settings are provided, None otherwise.
        """
        if self.config.subnets and self.config.security_group_ids:
            return {
                "EnableInterContainerTrafficEncryption": True,
                "EnableNetworkIsolation": False,
                "VpcConfig": {
                    "Subnets": self.config.subnets,
                    "SecurityGroupIds": self.config.security_group_ids,
                },
            }
        return None
