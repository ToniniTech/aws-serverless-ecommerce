# Production environment

This repository intentionally does not provide ready-to-apply production values. Copy the variable
surface only after selecting an AWS account, networking model, Product endpoint, alarm destinations,
database capacity, KMS strategy, deployment pipeline, and remote state backend.

The root `production_database_safety` check refuses `environment = "prod"` unless RDS uses Multi-AZ,
at least seven backup days, deletion protection, and a final snapshot on destroy. These are minimum
guardrails, not proof that the configuration is production-ready.
