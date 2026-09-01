# AWS Serverless E-Commerce

An educational AWS serverless variant of the existing RabbitMQ e-commerce project. It is a separate
Git repository so the original RabbitMQ and MySQL implementation remains independent.

## Current scope: Phase 8 local orchestration demo

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

HTTP API GET /orders/{orderId} --> read-only Order Query Lambda --> PostgreSQL
```

Order and Payment now use complete Transactional Outboxes. AWS calls run only in scheduled publisher
Lambdas after their local transactions commit. Rules fan payment results to independent Order and
Notification queues. Order applies guarded, idempotent `PENDING -> PAID/FAILED` transitions.
Notification persists a durable notification record and `ProcessedEvent` in one local transaction.
Its `eventId` uniqueness constraints absorb redelivery without generating a second notification.

Phase 6 adds structured request/event correlation, CloudWatch Embedded Metric Format Outbox health
metrics, focused alarms, and a workflow dashboard. It does not change delivery semantics or the
transaction boundaries introduced in Phase 5.

Phase 7 refactors repeated SQS and CloudWatch resources into tested Terraform modules, separates
environment values, adds state-migration declarations, restricts queue/endpoint/alarm resource
policies, and introduces account, database, API throttling, and retention guardrails.

Phase 8 adds a separate local Step Functions Order Saga: `ReserveStock -> ProcessPayment ->
ConfirmOrder`, with durable `CompensateStock` when payment fails. It is an orchestration comparison
only and does not replace the primary event choreography.

Deployment-readiness D1 adds an explicit `SIMULATED` Product profile for a low-cost deterministic
demo while preserving the synchronous `HTTP` adapter. It also adds a separate read-only Lambda and
`GET /orders/{orderId}` so the eventual Order result can be observed without database access.

Deployment-readiness D2 protects both Order routes with configurable API Gateway `AWS_IAM`
authorization by default. Approved callers must sign requests with SigV4 and have route-scoped
`execute-api:Invoke`; no caller credentials or broadly reusable caller role are created here.

Deployment-readiness D3 recorded a point-in-time build and account-guarded Terraform plan review.
That historical plan contained 146 creates, no updates, and no destroys, and no resources were
applied. The plan is intentionally not committed and is no longer treated as current; any future AWS
deployment must rebuild the artifacts, generate and review a fresh plan using a temporary non-root
role, and explicitly accept the state strategy for the short-lived development environment.

## Technology

- Java 17 Lambda handlers without a server framework;
- SNS, SQS, independent DLQs, and partial batch responses;
- EventBridge payment routing and scheduled Outbox publishers;
- Step Functions orchestration in an isolated local Saga demonstration;
- API Gateway HTTP API and a selectable synchronous Product adapter;
- PostgreSQL 16, explicit JDBC, HikariCP, and Flyway;
- RDS-managed Secrets Manager credentials;
- Docker Compose and Testcontainers;
- CloudWatch structured logs, embedded metrics, alarms, and dashboard;
- Terraform;
- Maven and JUnit 5.

No real AWS credentials, production database passwords, real AWS account IDs, or production secrets
are committed. Values such as `test`, local PostgreSQL credentials, and account `000000000000` are
documented emulator-only placeholders.

## Repository layout

```text
contracts/                           Messaging contracts and JSON validation
outbox-core/                         Bounded claim, retry, lease, and transport-independent processing
payment-order-created-lambda/        Payment domain, application, adapters, handler, migration
order-payment-result-lambda/         Order command/query, Outbox publisher, result consumer, and schema
notification-demo-lambda/            Durable Notification consumer, idempotency, and schema
saga-orchestration-lambda/            Explicit Saga tasks, compensation, and PostgreSQL schema
infrastructure/terraform/dev/        Environment root and service composition
infrastructure/terraform/local/      LocalStack-only messaging, Lambda, and Step Functions topology
infrastructure/terraform/modules/    Reusable SQS redrive and observability modules
infrastructure/terraform/environments/ Reviewed environment values; prod is intentionally incomplete
examples/                            Successful and failed OrderCreated examples
docs/                                Architecture, phase guides, and limitations
compose.yaml                         Local PostgreSQL and LocalStack
```

## Zero-cost local AWS simulation

The repository also contains a separate, non-billable local profile. Docker Compose runs PostgreSQL
and LocalStack; `infrastructure/terraform/local` provisions the messaging and Step Functions topology,
eleven Java 17 Lambdas, and four SQS event-source mappings against `http://localhost:4566`. It never applies
the AWS `dev` root. The end-to-end local exercise reaches `Payment COMPLETED` and `Order PAID` through
the same handlers, Outboxes, event contracts, and PostgreSQL constraints used by the AWS design. The
exercise also replays an `OrderCreated` event and verifies durable Notification idempotency.

Zero-cost hardening Z4 adds repeatable local exercises for a complete `PaymentFailed` flow,
duplicate payment-result delivery, an unavailable SNS publication boundary with Outbox recovery,
and Lambda/SQS retries through redrive to the dedicated Notification DLQ.

Z5 adds the isolated Step Functions Saga with real PostgreSQL reservation and compensation state. Its
demo proves successful confirmation, payment-failure compensation, and idempotent replay of both paths.

Current maintained LocalStack images require a free Hobby auth token for personal/non-commercial use.
The token belongs only in the ignored `.env` file. See the local guide before starting:

- [Zero-cost local development](docs/zero-cost-local-development.md)
- [Z4 local resilience exercises](docs/z4-local-resilience.md)
- [Phase 8 Step Functions Saga](docs/phase-8-step-functions-saga.md)

## Build and test

Start Docker Desktop so Testcontainers can execute the PostgreSQL integration suite, then run:

```powershell
.\mvnw.cmd clean verify
```

The shaded deployment artifacts are:

```text
payment-order-created-lambda/target/payment-order-created-lambda.jar
order-payment-result-lambda/target/order-payment-result-lambda.jar
notification-demo-lambda/target/notification-demo-lambda.jar
saga-orchestration-lambda/target/saga-orchestration-lambda.jar
```

If Docker is unavailable, the 19 real-database test methods are reported as skipped; unit and handler
tests still run.

## Local Payment and PostgreSQL

```powershell
Copy-Item .env.example .env
docker compose up -d payment-postgres

$env:DB_URL = "jdbc:postgresql://localhost:5433/payments?sslmode=disable"
$env:DB_USERNAME = "payment_local"
$env:DB_PASSWORD = "payment_local"
$env:DB_MAX_POOL_SIZE = "2"
$env:PAYMENT_PROCESSING_LEASE_SECONDS = "60"

.\mvnw.cmd clean package
java -cp payment-order-created-lambda\target\payment-order-created-lambda.jar `
  com.ecommerce.serverless.payment.PaymentLocalCli examples\order-created.json
```

Flyway runs when the Payment runtime initializes. Repeat the CLI command to observe durable duplicate
handling, or use `examples\order-created-payment-failed.json` for a deterministic `CARD_EXPIRED`
result.

Inspect the database:

```powershell
docker compose exec payment-postgres `
  psql -U payment_local -d payments -c "SELECT payment_id, order_id, status, source_event_id FROM payments;"

docker compose exec payment-postgres `
  psql -U payment_local -d payments -c "SELECT event_id, order_id, outcome FROM processed_events;"
```

Stop the local database while retaining its volume:

```powershell
docker compose down
```

## Payment behavior

| Condition | Persisted status |
|---|---|
| Amount greater than `1000.00` | `FAILED / AMOUNT_EXCEEDS_LIMIT` |
| Fractional amount equals `.13` | `FAILED / CARD_EXPIRED` |
| Otherwise | `COMPLETED` |

A business decline is successfully handled and is not retried. Invalid contracts, unavailable
PostgreSQL, or another infrastructure exception are returned as SQS batch failures.

PostgreSQL enforces one payment per order and source event. Reprocessing the same `eventId` does not
call the gateway again. Gateway calls use a stable key derived from `orderId`.

## AWS development deployment

The Terraform configuration creates billable resources, including RDS and a Secrets Manager
interface VPC endpoint. Review the plan carefully.

Prerequisites:

- AWS CLI authenticated through a temporary profile or standard credential provider;
- Terraform 1.9 or later;
- Docker and Java 17 for local verification;
- permission to create the declared networking, RDS, Secrets Manager, Lambda, SNS, SQS, EventBridge, IAM, and
  CloudWatch and API Gateway resources.

```powershell
.\mvnw.cmd clean verify

Set-Location infrastructure\terraform\dev
Copy-Item ..\environments\dev\terraform.tfvars.example ..\environments\dev\terraform.tfvars
# Set expected_aws_account_id in that file before planning.
terraform init
terraform fmt -check -recursive ..
terraform validate
terraform -chdir=..\modules\sqs-redrive-flow init -backend=false
terraform -chdir=..\modules\sqs-redrive-flow test
terraform -chdir=..\modules\observability init -backend=false
terraform -chdir=..\modules\observability test
terraform plan -var-file=..\environments\dev\terraform.tfvars -out deployment-d3.tfplan
terraform show deployment-d3.tfplan
# Stop here. Applying this plan belongs to D4 and requires separate approval.
```

Terraform asks RDS to manage the master password in Secrets Manager. The password is not a Terraform
variable or output. Payment Lambda runs in private subnets and reads only that secret through a
private interface endpoint.

## AWS behavior checks

Create an Order twice with the same idempotency key. The example dev variables use the deterministic
Product simulator and `AWS_IAM`. The following example uses `awscurl`, which signs requests through
the standard AWS credential chain without placing access keys in the repository:

```powershell
$api = terraform -chdir=infrastructure/terraform/dev output -raw order_api_endpoint
$region = "sa-east-1"
$profile = "your-temporary-profile"
$body = Get-Content examples/create-order.json -Raw
$response = awscurl --service execute-api --region $region --profile $profile `
  -X POST -H "content-type: application/json" -H "x-customer-id: customer-001" `
  -H "x-customer-email: customer@example.com" -H "x-correlation-id: corr-deployment-d2" `
  -H "idempotency-key: deployment-d2-request-001" --data $body "$api/orders"
$created = $response | ConvertFrom-Json
awscurl --service execute-api --region $region --profile $profile "$api/orders/$($created.orderId)"
```

The first response is `201`; the duplicate returns the original Order with `duplicate=true` and does not
reserve stock again during sequential replay. Within roughly one schedule interval, the Order Outbox
publishes to SNS. Payment stores its result and Outbox atomically, the Payment publisher sends the result
to EventBridge, and the Order result Lambda transitions the original row. Publisher crashes may cause
stable event republication; consumers absorb duplicates.

RDS is private, so direct local database access is intentionally unavailable without an approved
administrative path such as a temporary SSM tunnel; none is provisioned in this phase.

After deployment, open the dashboard and subscribe an operator endpoint to the alarm topic:

```powershell
terraform -chdir=infrastructure/terraform/dev output -raw observability_dashboard_name
terraform -chdir=infrastructure/terraform/dev output -raw operational_alarm_topic_arn
```

Terraform deliberately creates no email/SMS subscription: confirmation and endpoint ownership are
external operational decisions. See the Phase 6 runbook for Logs Insights queries and alarm tests.

## Documentation

- [Phase 2/3 guide](docs/phase-2-3.md)
- [Phase 4 guide](docs/phase-4.md)
- [Phase 5 guide](docs/phase-5.md)
- [Phase 6 observability runbook](docs/phase-6.md)
- [Phase 7 Terraform and IAM guide](docs/phase-7.md)
- [Phase 8 Step Functions Saga](docs/phase-8-step-functions-saga.md)
- [Deployment readiness D1](docs/deployment-readiness-d1.md)
- [Deployment readiness D2](docs/deployment-readiness-d2.md)
- [Deployment readiness D3 plan review](docs/deployment-readiness-d3.md)
- [Phase 1 runbook](docs/phase-1.md)
- [Architecture comparison](docs/aws-serverless-architecture.md)
- [Known limitations](docs/known-limitations.md)
- [Zero-cost local development](docs/zero-cost-local-development.md)
- [Z4 local resilience exercises](docs/z4-local-resilience.md)

## Cleanup

```powershell
terraform -chdir=infrastructure/terraform/dev destroy
```

RDS is configured for educational development with `skip_final_snapshot = true`; destroying it
permanently removes its data. No cleanup is run automatically.
