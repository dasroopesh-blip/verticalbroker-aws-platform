"""Market Data Ingestion Service.

Processes real-time market data from Bloomberg B-Pipe and Thomson Reuters feeds
via Kinesis Data Streams, validates schema, enriches metadata, writes Parquet
micro-batches to S3 Bronze layer, and registers partitions in Glue Data Catalog.

Requirements: 1.1, 1.2, 1.5, 1.6, 7.1, 7.4
"""
