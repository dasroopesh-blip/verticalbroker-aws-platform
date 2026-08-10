"""VerticalBroker ETL pipeline modules.

Contains PySpark-based ETL jobs for the medallion architecture:
- bronze_to_silver: Raw data cleansing, validation, and deduplication
- silver_to_gold: Business-level aggregation and enrichment
- data_quality: Configurable data quality framework with severity-based handling
"""
