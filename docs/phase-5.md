# Phase 5: Order and Payment Transactional Outboxes

> **Historical phase snapshot.** This document describes the repository when the complete Order and
> Payment Outboxes were introduced. Later phases added observability, Terraform/IAM hardening,
> configurable API authorization, the Order query, and the isolated local Saga. See the
> [main README](../README.md) and [current architecture](aws-serverless-architecture.md) for the final state.

## Outcome

Phase 5 makes the AWS flow end to end and removes both database-to-messaging dual writes:

```text
POST /orders
  -> synchronous Product REST reservation
  -> one PostgreSQL transaction: Order + OrderItems + OrderOutbox
  -> scheduled Order Outbox publisher
  -> SNS order-events
  -> Payment SQS/Lambda
  -> one PostgreSQL transaction: Payment + input ProcessedEvent + PaymentOutbox
  -> scheduled Payment Outbox publisher
  -> EventBridge payment-events
  -> Order and Notification result queues
```

Order still calls Product synchronously. Step Functions is not used in this primary choreography.

## Atomic boundaries

Order guarantees:

```text
COMMIT = Order + OrderItems + OrderCreated Outbox row
```

Payment guarantees:

```text
COMMIT = terminal Payment + OrderCreated ProcessedEvent + Payment result Outbox row
```

Neither guarantee includes SNS or EventBridge. PostgreSQL cannot atomically commit an AWS API call.
The Outbox makes the intent to publish durable so temporary AWS failure does not lose a business event.

## Publisher algorithm

Each EventBridge schedule invokes its publisher once per minute. A publisher:

1. Selects at most `OUTBOX_BATCH_SIZE` eligible rows.
2. Uses `FOR UPDATE SKIP LOCKED` to avoid rows held by another worker.
3. Changes them to `PROCESSING`, increments `attempt_count`, records `claimed_at`, and commits.
4. Publishes without holding database locks.
5. Marks accepted events `PUBLISHED`.
6. Returns failures to `PENDING` with bounded exponential backoff.

If a worker crashes while `PROCESSING`, another worker can reclaim the row after
`OUTBOX_CLAIM_LEASE_SECONDS`. The default batch is 10 and the default lease is 120 seconds.

`SKIP LOCKED` solves a real multi-worker problem: without it, workers can block each other or claim the
same candidates. The Terraform functions allow two concurrent publisher environments. The claim
transaction is short and never wraps SNS or EventBridge network latency.

## Delivery and duplicates

The publisher can crash after AWS accepts an event but before the `PUBLISHED` update. The row is later
reclaimed and published again. This is at-least-once publication, not exactly once.

- OrderCreated keeps its stored Outbox `eventId`.
- Payment results use `payment-result-{paymentId}`.
- Payment, Order result, and any real Notification side-effect consumer must be idempotent.

Published rows are retained for study and diagnostics. Production needs an explicit archival/purge
policy; deleting history is not part of this phase.

## Order command path

API Gateway exposes `POST /orders`. Required headers are:

- `x-customer-id`;
- `x-customer-email`;
- `idempotency-key`;
- optional `x-correlation-id`.

The body contains only `productId` and `quantity`. The Product adapter calls the existing contract:

```text
PATCH /api/products/{productId}/decreaseStock
```

Product remains authoritative for name, price, active state, and stock. Order calculates totals from
the returned price and never accepts a client price.

The Product endpoint must be privately reachable from the Lambda VPC. Terraform does not create a NAT
gateway. `product_service_cidr` and `product_service_port` restrict network egress.

## Product consistency limitation

Product calls happen before the Order database transaction. This avoids holding a database transaction
open across REST, but Product and Order are not atomic. If a later item or the Order commit fails, an
earlier reservation requires compensation. Phase 8 demonstrates that compensation explicitly.

Sequential requests with the same idempotency key return the stored Order without another Product call.
A truly concurrent race can still reserve twice before PostgreSQL's unique constraint chooses a winner;
a production design should add a durable request claim/lease or Product reservation idempotency key.

## Database design

Both Outbox tables use:

- UUID primary key;
- unique stable `event_id`;
- JSONB payload containing the immutable messaging contract;
- constrained `PENDING`, `PROCESSING`, and `PUBLISHED` states;
- attempt, claim, retry, publication, creation, and update timestamps;
- `(status, next_attempt_at, created_at)` claim index.

Order tables remain in `order_domain`; Payment tables remain in `public`.

## IAM and networking

The SQS Payment consumer no longer has `events:PutEvents`. Only the Payment Outbox publisher may publish
to the custom payment bus. Only the Order Outbox publisher may publish to `order-events` SNS. Private
EventBridge, SNS, and Secrets Manager endpoints avoid hardcoded credentials and NAT cost.

The Order command role has no messaging permission. Its responsibility is Product REST plus local
database persistence. API Gateway was unauthenticated at this phase boundary. Deployment-readiness
[D2](deployment-readiness-d2.md) subsequently added configurable `AWS_IAM` authorization; customer
headers still must not be treated as production identity.

## Verification

Run:

```powershell
.\mvnw.cmd clean verify
terraform -chdir=infrastructure/terraform/dev fmt -check
terraform -chdir=infrastructure/terraform/dev validate
```

The PostgreSQL integration suite covers atomic Outbox creation, duplicate command replay, AWS transport
failure, later republication, stale/bounded claims, `SKIP LOCKED`, Payment idempotency, and Order result
idempotency. No AWS resources are applied automatically.
