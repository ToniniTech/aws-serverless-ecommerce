# Zero-Cost Local AWS Development

This guide describes the local learning environment. It sends no request to an AWS account and
provisions no billable cloud resource.

## Z5 scope

Z4 runs the existing Java handlers as Lambda functions inside LocalStack, connects them to local
PostgreSQL:

```text
API Gateway fixture -> Order Command Lambda -> SIMULATED Product adapter
                              |
                              +-> PostgreSQL: Order + Order Outbox
                                                   |
                                      Order Outbox Lambda -> SNS order-events
                                          +-> Payment SQS -> Payment Lambda
                                          +-> Notification SQS -> Notification Lambda
                                                                          |
                                                              PostgreSQL: Notification
                                                              + ProcessedEvent

Payment Lambda -> PostgreSQL: Payment + ProcessedEvent + Payment Outbox
                                                        |
                                           Payment Outbox Lambda -> EventBridge
                                               +-> Order SQS -> Order result Lambda -> PAID/FAILED
                                               +-> Notification SQS -> Notification Lambda
                                                                                 |
                                                                     PostgreSQL: Notification
                                                                     + ProcessedEvent

API Gateway fixture -> Order Query Lambda -> PostgreSQL
```

The local Terraform root creates eleven Java 17 Lambda functions, four SQS event-source mappings, the
SNS/SQS fan-out, four independent DLQs, the custom EventBridge routing topology, and one isolated
Step Functions Order Saga. The Product port uses the deterministic `SIMULATED` adapter, so no Product
Service process is required.

## Cost and credential boundary

LocalStack Hobby is intended for personal, non-commercial learning and is free. Maintained LocalStack
images require a Developer Token. Keep it only in the ignored `.env` file.

`AWS_ACCESS_KEY_ID=test` and `AWS_SECRET_ACCESS_KEY=test` are emulator identifiers, not AWS
credentials. The local provider uses explicit LocalStack endpoints and disables AWS credential,
metadata, region, and account validation. Never place real AWS credentials in `.env`.

The local root contains no RDS, VPC, VPC endpoint, Secrets Manager, API Gateway, or real CloudWatch
resource. It is separate from `infrastructure/terraform/dev`.

## Prerequisites

- Docker Desktop with the Docker Engine running;
- a free LocalStack Hobby auth token;
- Java 17 and PowerShell;
- network access on the first run to pull the LocalStack and Java Lambda runtime images.

The repository includes Maven Wrapper and a Terraform executable. AWS commands run inside the
LocalStack container, so a host AWS CLI is not required.

## Configure once

```powershell
Copy-Item .env.example .env
```

Set only the local token in `.env`:

```text
LOCALSTACK_AUTH_TOKEN=your-localstack-developer-token
```

The Compose network defaults to `aws-serverless-ecommerce_default`. LocalStack starts Lambda runtime
containers on that network so they can reach `payment-postgres` by service name. LocalStack also needs
the Docker socket to create those short-lived runtime containers. This is appropriate for a local
learning machine, but it is a privileged host integration and is not an application deployment model.

## Build, start, and provision

Run these commands from the repository root:

```powershell
./scripts/local/build.ps1
./scripts/local/start.ps1
./scripts/local/provision.ps1
```

`build.ps1` runs the Java tests and creates four shaded deployment JARs. `start.ps1` starts PostgreSQL
and LocalStack and waits for their health checks. `provision.ps1` applies only
`infrastructure/terraform/local` to `http://localhost:4566` and fake account `000000000000`.

Terraform is repeatable. Rebuilding a JAR and running `provision.ps1` updates the affected local Lambda
in place. PostgreSQL and LocalStack use named volumes, so ordinary container restarts can retain their
state. If the emulator is recreated or its topology is absent, run `provision.ps1` again; it only
recreates local resources in fake account `000000000000`.

## Run the end-to-end happy path

```powershell
./scripts/local/happy-path.ps1
```

The script:

1. invokes Order Command with an API Gateway v2 event fixture;
2. verifies that Order and Order Outbox were committed together;
3. invokes the Order Outbox publisher;
4. lets the SQS event-source mapping invoke Payment automatically;
5. verifies Payment and Payment Outbox persistence;
6. invokes the Payment Outbox publisher;
7. lets EventBridge, SQS, and the Order consumer transition the Order to `PAID`;
8. invokes Order Query and checks the final projection;
9. waits for the `OrderCreated` and `PaymentProcessed` Notification records;
10. replays the original `OrderCreated` envelope directly to Notification;
11. verifies that Notification still has exactly two records and two processed-event rows.

The two Outbox publishers are invoked explicitly to make the local exercise fast and deterministic.
The AWS development design invokes them on EventBridge schedules. This changes only the trigger, not
the atomic database transaction or at-least-once publication semantics.

## Low-level messaging exercises

```powershell
./scripts/local/smoke-test.ps1
./scripts/local/dlq-test.ps1
```

The smoke test proves SNS fan-out and EventBridge rule routing by inspecting each independent queue.
The DLQ test leaves a message unacknowledged and proves redrive after `maxReceiveCount = 3`. These
scripts temporarily disable the SQS event-source mappings and restore them in a `finally` block so the
Lambda consumers cannot race the inspection.

The normal source-queue visibility timeout is 30 seconds, matching the Lambda timeout. The focused DLQ
exercise overrides visibility to zero on each manual receive so it completes quickly. In the actual
consumer flow, successful batch records are deleted; failed records become visible after the timeout,
their receive count increases, and SQS eventually redrives them. There is no SQS equivalent of calling
RabbitMQ `basicAck()` or `basicNack()` directly in application code.

## Run the resilience suite

```powershell
./scripts/local/resilience-suite.ps1
```

The Z4 suite performs four connected checks across three scripts:

1. creates an Order above the simulated payment limit, observes `Payment FAILED`, routes
   `PaymentFailed` through EventBridge, and verifies `Order FAILED` plus both durable Notification
   records;
2. republishes that stable payment result and verifies that Order version, Order processed events,
   Notification records, and Notification processed events do not increase;
3. points the local Order Outbox Lambda at a nonexistent local SNS topic, verifies `PENDING` with a
   recorded failure, restores its original environment, and verifies successful republication;
4. sends a valid `OrderCreated` directly to the Notification source queue with the test-only
   `forceFailure=true` attribute, then observes Lambda partial-batch failure, SQS redelivery, and
   movement to its DLQ after `maxReceiveCount = 3`.

The component exercises can also be run independently:

```powershell
./scripts/local/failure-path.ps1
./scripts/local/outbox-recovery-test.ps1
./scripts/local/consumer-dlq-test.ps1
```

The recovery script restores the original local Lambda environment in a `finally` block. The DLQ
script similarly restores the normal queue visibility timeout. Neither script changes the AWS
development Terraform root.

## Run the Step Functions Saga

```powershell
./scripts/local/saga-demo.ps1
```

Z5 keeps this orchestration separate from the choreography. The state machine invokes explicit
`ReserveStock`, `ProcessPayment`, `ConfirmOrder`, and `CompensateStock` Lambdas. Their durable state is
stored under the independent `saga_demo` PostgreSQL schema.

The script proves an approved payment reaches `CONFIRMED`, a deterministic `CARD_EXPIRED` result
restores the reservation, and repeating either business Saga does not repeat its side effects. See
[Phase 8](phase-8-step-functions-saga.md) for the state model, retry policy, and trade-offs.

## Inspect logs and data

```powershell
docker compose logs -f localstack

docker compose exec payment-postgres `
  psql -U payment_local -d payments -c "SELECT order_id, status FROM payments;"

docker compose exec payment-postgres `
  psql -U payment_local -d payments -c "SELECT order_id, status FROM order_domain.orders;"

docker compose exec payment-postgres `
  psql -U payment_local -d payments -c "SELECT event_id, event_type, status FROM notification_domain.notifications;"

docker compose exec payment-postgres `
  psql -U payment_local -d payments -c "SELECT event_id, processed_at FROM notification_domain.notification_processed_events;"
```

Lambda output is also available through the emulated `/aws/lambda/<function-name>` log groups.
Structured logs include event IDs, correlation IDs, order IDs, receive counts, and AWS request IDs.

## Stop safely

```powershell
docker compose down
```

This stops the containers while retaining both named volumes. `docker compose down -v` would delete
the local PostgreSQL data and LocalStack state; use it only when you deliberately want a clean reset.

## Notification transaction and idempotency boundary

Notification treats `OrderCreated`, `PaymentProcessed`, and `PaymentFailed` as messaging contracts,
not persistence entities. For each accepted event it atomically inserts:

- one `notification_domain.notifications` row representing the notification to generate;
- one `notification_domain.notification_processed_events` row representing consumption by this
  consumer.

Both tables enforce uniqueness around the stable `eventId`. Concurrent or sequential redelivery
therefore returns the original notification ID and produces no additional row. If either insert fails,
the transaction rolls back and SQS may retry the message.

This boundary does not claim that an external email or SMS has been delivered exactly once. A real
provider call cannot participate in the PostgreSQL transaction. Adding delivery later should use a
Delivery Outbox (or an equivalent durable dispatch state) so that the database commit and subsequent
provider retry remain recoverable and idempotent.

## What Z5 proves—and what it does not

Z5 includes all Z4 exercises of real application handlers, AWS SDK calls, event envelopes, database migrations,
transactions, Outboxes, idempotency constraints, fan-out, routing, visibility retries, DLQs, and
eventual state changes. It additionally proves connected business-failure convergence, stable-event
replay, durable Notification idempotency, publisher recovery, and SQS/Lambda redrive behavior. These
skills transfer directly to production design and debugging.

LocalStack remains an emulator. Z5 does not prove real IAM enforcement, AWS-managed scaling, cold-start
behavior, regional availability, service quotas, network latency, billing controls, or exact CloudWatch
parity. The Step Functions exercise additionally does not prove AWS execution-history, quota, or IAM
behavior. A later tightly controlled AWS deployment is still valuable, but it should validate cloud-only
behavior rather than serve as the first place where application logic is tested.

The local Lambda runtime startup allowance is configured separately from the application timeout.
This prevents a slow first Java runtime container startup on a development laptop from exhausting the
emulator's default startup window; it does not change the Lambda timeout configured in Terraform.
