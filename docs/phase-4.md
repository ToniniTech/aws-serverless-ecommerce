# Phase 4: EventBridge Payment Results

> **Historical phase snapshot.** This document describes the direct EventBridge publication design
> at the end of Phase 4. Phase 5 subsequently replaced its dual-write boundary with complete Order
> and Payment Transactional Outboxes. See the [main README](../README.md) and
> [current architecture](aws-serverless-architecture.md) for the final state.

## Outcome

Phase 4 connects terminal Payment results to Order and Notification through a custom EventBridge bus.
It does not replace the existing SNS fan-out for `OrderCreated` and does not introduce Step Functions.

```text
Payment Lambda
  -> EventBridge custom bus: payment-events
      -> PaymentProcessed rule
      |   +-> order-payment-result-queue -> Order Payment Result Lambda
      |   +-> notification-payment-result-queue -> Notification Demo Lambda
      |
      -> PaymentFailed rule
          +-> order-payment-result-queue -> Order Payment Result Lambda
          +-> notification-payment-result-queue -> Notification Demo Lambda
```

Both queues have independent DLQs and `maxReceiveCount = 5` by default.

## Event contracts

`PaymentProcessedEvent` and `PaymentFailedEvent` are messaging records in the `contracts` module. They
are not persistence entities. EventBridge uses:

- `source`: `com.ecommerce.payment`;
- `detail-type`: `PaymentProcessed` or `PaymentFailed`;
- `detail`: the complete versioned business event;
- stable result `eventId`: `payment-result-{paymentId}`.

SQS receives the complete EventBridge envelope. Consumers validate its source, detail type, detail
contract, amount, currency, identifiers, and terminal-result-specific fields.

## Payment publication gap identified in Phase 4 and resolved in Phase 5

The sequence at the end of Phase 4 was:

1. Claim and process `OrderCreated` idempotently.
2. Commit terminal Payment plus its input `ProcessedEvent` in PostgreSQL.
3. Call EventBridge `PutEvents`.
4. Acknowledge the SQS record only after EventBridge accepts the entry.

If publication fails, Lambda reports that individual SQS record as failed. On retry, Payment recognizes
the input event as a duplicate, does not charge again, reconstructs the same result from PostgreSQL, and
republishes the same stable result event. Downstream consumers must therefore remain idempotent.

This was not an atomic PostgreSQL-plus-EventBridge transaction. [Phase 5](phase-5.md) resolved the
gap by changing the local atomic boundary to `Payment + ProcessedEvent + PaymentOutbox` and publishing
the Outbox asynchronously. The current implementation uses that resolved design.

## Order state and idempotency

The Order consumer parses the EventBridge envelope and starts one local PostgreSQL transaction:

1. Return immediately if `eventId` already exists in `order_processed_events`.
2. Lock the matching Order row using `SELECT ... FOR UPDATE`.
3. Require `PENDING`, or accept an already-applied identical terminal state.
4. Update `PENDING -> PAID` or `PENDING -> FAILED`.
5. Insert `order_processed_events`.
6. Commit both changes together.

`event_id` is the primary key, and additional foreign-key, unique, check, and status/time indexes
protect the educational schema. A missing Order or contradictory terminal result is retryable and can
eventually reach the Order result DLQ. Notification never owns or updates Order state.

Order owns the `order_domain` PostgreSQL schema and its `order_flyway_schema_history`; Payment retains
the `public` schema and its own Flyway history. The dev environment shares one small RDS instance to
control cost, but schema ownership and runtime modules remain separate.

## Networking and least privilege

Payment Lambda is in private subnets. A private EventBridge interface endpoint lets it call
`PutEvents` without a NAT gateway. Its IAM role and endpoint policy are restricted to the custom bus.
Order Lambda has a separate security group and IAM role and can only consume its queue, write its log
group, read the RDS-managed secret, and manage the network interfaces required by VPC Lambda.

## Retry model

No `basicAck()` equivalent is called. A successful Lambda batch item is deleted by the Lambda/SQS
integration. A failed item becomes visible again after the visibility timeout. SQS increments its
receive count and moves it to that flow's DLQ after the configured maximum.

Payment and Order handlers use partial batch responses, so one invalid or unavailable record does not
force successful records in the same batch to retry.

## Test locally

Docker Desktop is required for the real PostgreSQL integration tests:

```powershell
.\mvnw.cmd clean verify
```

The suite covers contract validation, Payment publication failure retry, Payment idempotency, successful
and failed Order transitions, duplicate payment results, contradictory results, missing orders, handler
partial failures, and Notification observation of EventBridge envelopes.

Validate infrastructure without deploying:

```powershell
terraform -chdir=infrastructure/terraform/dev fmt -check
terraform -chdir=infrastructure/terraform/dev validate
```

No AWS resources are applied automatically.
