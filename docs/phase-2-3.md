# Phase 2/3: Durable Payment with PostgreSQL

> **Historical phase snapshot.** This document describes the repository at the end of Phase 2/3,
> before payment-result routing and Transactional Outboxes were added. See the
> [main README](../README.md) and [current architecture](aws-serverless-architecture.md) for the final state.

## Scope

Combined Phase 2/3 replaces the Payment transport stub with a durable idempotent consumer. Combining
the phases avoids creating an in-memory repository that would immediately be discarded.

Implemented:

- deterministic successful and failed payment rules;
- PostgreSQL persistence through explicit JDBC;
- Flyway migrations;
- durable `processed_events` idempotency;
- unique order, source event, gateway key, and transaction constraints;
- stable gateway idempotency keys;
- bounded HikariCP connections;
- local PostgreSQL through Docker Compose;
- PostgreSQL integration tests through Testcontainers;
- minimal private RDS PostgreSQL and RDS-managed Secrets Manager credentials for AWS dev.

Not implemented during this phase, with later resolution noted:

- EventBridge result publication — added directly in [Phase 4](phase-4.md) and moved behind the
  Payment Outbox in [Phase 5](phase-5.md);
- Payment Outbox — added in [Phase 5](phase-5.md);
- Order result updates — added in [Phase 4](phase-4.md);
- real payment-provider HTTP calls — still intentionally outside the educational implementation;
- Notification persistence — added later to the current implementation; external delivery remains
  intentionally out of scope as documented in [Known Limitations](known-limitations.md).

## Code boundaries

```text
Lambda/SQS adapter
  PaymentOrderCreatedHandler
        |
        v
Application
  PaymentApplicationService
  PaymentGateway port
  PaymentProcessingRepository port
        |
        +--> SimulatedPaymentGateway
        |
        +--> JdbcPaymentProcessingRepository
                 |
                 v
              PostgreSQL
```

AWS event envelopes remain in the handler. Payment domain and application classes do not depend on
SQS, Lambda, RDS, or Secrets Manager types. Persistence records are not messaging contracts.

## Payment rules

The deterministic simulator preserves the useful rules from the RabbitMQ implementation:

| Condition | Result |
|---|---|
| Amount greater than `1000.00` | `FAILED / AMOUNT_EXCEEDS_LIMIT` |
| Fractional amount equals `.13` | `FAILED / CARD_EXPIRED` |
| Otherwise | `COMPLETED` |

Random decline behavior was removed because it makes tests and demonstrations nondeterministic.
A business decline is a successfully processed message: the `FAILED` Payment and ProcessedEvent are
committed, and the SQS record is not returned in `batchItemFailures`.

## Idempotency and concurrency

The first local transaction attempts to insert a `PROCESSING` payment claim. PostgreSQL constraints
provide the final concurrency guard:

- `UNIQUE(order_id)` prevents a second payment for one order;
- `UNIQUE(source_event_id)` protects the stable source `eventId`;
- `UNIQUE(gateway_idempotency_key)` protects reuse of the provider key;
- `processed_events.event_id` is the primary key;
- `processed_events.payment_id` references `payments.id`.

`ON CONFLICT DO NOTHING` is used for the initial claim. This avoids relying on a read-then-insert
check that two concurrent Lambda invocations could both pass.

If the same event is already terminal, it is returned as a duplicate without calling the gateway.
If the same order arrives with a different event ID, the database uniqueness constraint prevents a
second payment and the new event is recorded with outcome `DUPLICATE_ORDER`.

## External-call crash window

The gateway cannot participate in a PostgreSQL transaction:

```text
1. Commit PROCESSING claim
2. Call gateway with stable idempotency key
3. Transactionally commit terminal Payment + ProcessedEvent
```

A crash after step 2 but before step 3 causes SQS redelivery. After the processing lease expires,
Payment calls the gateway again with the same key. A real gateway adapter must forward that key and
rely on the provider's idempotency contract. This design does not claim exactly-once charging.

The second transaction atomically commits:

```text
Payment COMPLETED or FAILED + ProcessedEvent
```

EventBridge publication was deliberately absent at this phase boundary. Phase 4 subsequently added
direct result publication, and Phase 5 replaced that boundary with `PaymentOutbox` so publishing a
payment result could not reintroduce the dual-write gap.

## PostgreSQL schema

Flyway migration `V1__create_payment_tables.sql` creates `payments`, `processed_events`, checks,
foreign keys, unique constraints, and focused indexes. Flyway uses its own schema history table.

The Lambda runs migration validation/application during cold initialization. This is convenient for
an educational dev environment, but it means the current Lambda uses the RDS-managed master secret.
A production implementation should run migrations as a separate deployment task and give the
runtime a narrower database role.

## Connection limits

Each warm Payment Lambda environment has a HikariCP maximum pool size of two. Terraform limits both
reserved Lambda concurrency and SQS mapping concurrency to two. The intended upper bound is roughly
four application connections, plus temporary migration/administrative use.

This is a deliberate limit, not a claim that Lambda and relational databases scale safely without
connection planning. RDS Proxy remains postponed until measurements justify it.

## AWS development topology

```text
Private subnet A ---+
                     +--> RDS PostgreSQL (single AZ instance)
Private subnet B ---+
       |
       +--> Payment Lambda ENIs
       +--> Secrets Manager interface VPC endpoint
```

RDS is encrypted, private, single-AZ, and uses an RDS-managed master password stored in Secrets
Manager. Terraform never receives or outputs the password. Payment Lambda may retrieve only that
secret ARN. Security groups permit only Payment Lambda to RDS on TCP 5432 and to the Secrets Manager
endpoint on TCP 443. No NAT Gateway is created.

The execution role also needs EC2 network-interface actions because Lambda creates Hyperplane ENIs
for VPC attachment. Those actions require `Resource: *`; queue, secret, and log permissions remain
scoped to their specific ARNs.

## Local development

Start the reusable local database:

```powershell
Copy-Item .env.example .env
docker compose up -d payment-postgres
```

Build the shaded JAR, set the local variables from `.env.example`, and execute the same application
wiring without LocalStack:

```powershell
$env:DB_URL = "jdbc:postgresql://localhost:5433/payments?sslmode=disable"
$env:DB_USERNAME = "payment_local"
$env:DB_PASSWORD = "payment_local"
$env:DB_MAX_POOL_SIZE = "2"
$env:PAYMENT_PROCESSING_LEASE_SECONDS = "60"

.\mvnw.cmd clean package
java -cp payment-order-created-lambda\target\payment-order-created-lambda.jar `
  com.ecommerce.serverless.payment.PaymentLocalCli examples\order-created.json
```

Running the same command again demonstrates durable duplicate handling. Use
`examples/order-created-payment-failed.json` to persist a deterministic decline.

## Testing

```powershell
.\mvnw.cmd clean verify
```

With Docker running, Testcontainers creates a disposable PostgreSQL 16 instance, applies Flyway,
and verifies:

- successful payment and ProcessedEvent persistence;
- duplicate event suppression;
- failed payment persistence;
- one payment when the same order arrives under a second event ID.

Handler and application unit tests cover partial SQS failures, retryable infrastructure errors,
business-decline acknowledgement, stable gateway keys, duplicates, and in-progress claims.

At this phase boundary, the integration test class used `disabledWithoutDocker = true` and contained
four database tests. The current repository has additional integration suites; see the main README
for the current build behavior.
