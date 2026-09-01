# AWS Serverless E-Commerce

Event-driven e-commerce backend designed for AWS and implemented with Java 17 and Terraform. It demonstrates transactional outboxes, idempotent consumers, asynchronous payment processing, dead-letter queues, observability, and Saga compensation.

The complete architecture can be exercised locally with PostgreSQL, Docker, Testcontainers, and LocalStack without provisioning billable AWS resources.

## Architecture overview

```text
HTTP API --> Order Command Lambda --> Product port --> SIMULATED catalog (default)
                    |                              +--> Product Service REST (HTTP profile)
                    |
                    +--> PostgreSQL: Order + Items + Order Outbox
                                     |
                        scheduled Order Outbox publisher --> SNS order-events
                          +--> payment-order-created-queue --> Payment Lambda
                          |       +--> PostgreSQL: Payment + ProcessedEvent + Payment Outbox
                          |                         |
                          |             scheduled Payment Outbox publisher --> EventBridge payment-events
                          |                 +--> order-payment-result-queue --> Order result Lambda
                          |                 +--> notification-payment-result-queue --> Notification Lambda
                          +--> notification-order-created-queue --> Notification Lambda
                                                                        |
                                                              PostgreSQL: Notification
                                                              + ProcessedEvent

HTTP API GET /orders/{orderId} --> Order Query Lambda --> PostgreSQL
```

Order and Payment persist state changes and outgoing events atomically through Transactional Outboxes. Publisher Lambdas send those events after the database transaction commits. Consumers use stable event identifiers and database uniqueness constraints to absorb retries and duplicate delivery.

The primary workflow uses event choreography through SNS, SQS, and EventBridge. A separate LocalStack demonstration implements an explicit Step Functions Saga with `ReserveStock`, `ProcessPayment`, `ConfirmOrder`, and `CompensateStock` tasks for comparison.

## Key capabilities

- Java 17 Lambda handlers without a server framework;
- asynchronous Order, Payment, and Notification workflows;
- Transactional Outbox processing with bounded claims, leases, and retries;
- idempotent consumers and guarded Order state transitions;
- SNS fan-out, SQS queues, independent DLQs, and partial batch responses;
- EventBridge routing for successful and failed payment results;
- API Gateway Order command and read-only query endpoints;
- selectable simulated or HTTP Product adapter;
- PostgreSQL persistence with JDBC, HikariCP, and Flyway;
- structured logs, correlation identifiers, CloudWatch metrics, alarms, and dashboard;
- reusable, tested Terraform modules;
- local happy-path, failure, recovery, duplicate-delivery, and DLQ exercises.

## Technology stack

Java 17, Maven, JUnit 5, AWS Lambda, API Gateway, SNS, SQS, EventBridge, Step Functions, CloudWatch, Secrets Manager, PostgreSQL 16, Flyway, HikariCP, Terraform, Docker Compose, Testcontainers, and LocalStack.

## Repository structure

```text
contracts/                            Messaging contracts and validation
outbox-core/                          Transport-independent Outbox processing
payment-order-created-lambda/         Payment processing and Payment Outbox
order-payment-result-lambda/          Order command, query, result, and Outbox handlers
notification-demo-lambda/             Durable, idempotent Notification consumer
saga-orchestration-lambda/            Step Functions Saga tasks and compensation
infrastructure/terraform/dev/         AWS development environment
infrastructure/terraform/local/       LocalStack messaging and Lambda topology
infrastructure/terraform/modules/     Reusable infrastructure modules
scripts/local/                        PowerShell build and exercise scripts
scripts/bash/local/                   Bash equivalents for local workflows
docs/                                 Architecture, operations, and design notes
examples/                             Example commands and domain events
```

## Quick start

Prerequisites:

- Java 17;
- Docker Desktop with the Docker Engine running;
- PowerShell;
- a LocalStack Hobby auth token for the maintained LocalStack image.

Create the ignored local environment file and set only your LocalStack token:

```powershell
Copy-Item .env.example .env
```

```text
LOCALSTACK_AUTH_TOKEN=your-localstack-developer-token
```

Build the project, start PostgreSQL and LocalStack, and provision the local topology:

```powershell
./scripts/local/build.ps1
./scripts/local/start.ps1
./scripts/local/provision.ps1
```

Run the complete happy path:

```powershell
./scripts/local/happy-path.ps1
```

The local Terraform root uses explicit LocalStack endpoints and fake account `000000000000`; it does not contact an AWS account. See [Zero-cost local development](docs/zero-cost-local-development.md) for the complete setup, resilience suite, messaging checks, and cleanup instructions.

## Build and test

Run the complete Maven reactor from the repository root:

```powershell
.\mvnw.cmd clean verify
```

Docker enables the PostgreSQL integration tests through Testcontainers. If Docker is unavailable, those tests are reported as skipped while unit and handler tests continue to run.

The build generates shaded deployment artifacts under each Lambda module's ignored `target/` directory.

## AWS deployment

The AWS development Terraform root models the same application with real AWS services, including billable resources such as RDS, CloudWatch, and a Secrets Manager VPC endpoint. Nothing is provisioned automatically.

Before deploying, use temporary non-root AWS credentials, configure the expected account guard, choose an explicit Terraform state strategy, generate a fresh plan, and review all estimated resources and costs. Start with the [deployment readiness review](docs/deployment-readiness-d3.md) and the [architecture guide](docs/aws-serverless-architecture.md).

RDS manages the database master password through Secrets Manager. Real AWS credentials, production passwords, account IDs, Terraform state, plans, and local `.env` files must never be committed.

## Documentation

- [Architecture and design comparison](docs/aws-serverless-architecture.md)
- [Zero-cost local development](docs/zero-cost-local-development.md)
- [Local resilience exercises](docs/z4-local-resilience.md)
- [Step Functions Saga](docs/phase-8-step-functions-saga.md)
- [Observability runbook](docs/phase-6.md)
- [Terraform and IAM guide](docs/phase-7.md)
- [Deployment readiness](docs/deployment-readiness-d1.md)
- [Known limitations](docs/known-limitations.md)

The remaining phase documents preserve the implementation decisions and incremental engineering history without making that chronology part of the project's main presentation.

## Scope and limitations

This is an educational architecture project, not a production-ready commerce platform. The Notification component persists durable notification intents but does not contact an external email or messaging provider. The default Product and Payment integrations are deterministic simulators, delivery remains at least once, and the isolated Step Functions Saga is not connected to the primary HTTP workflow.

See [Known limitations](docs/known-limitations.md) for the complete consistency, authentication, availability, observability, and operational boundaries.
