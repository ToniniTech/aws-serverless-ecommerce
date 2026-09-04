# Phase 8: Step Functions Order Saga

> **Historical phase snapshot.** This document records the isolated local Saga increment introduced
> in Phase 8. The Saga remains part of the current repository, but it does not replace or connect to
> the primary choreography. See the [main README](../README.md) and
> [current architecture](aws-serverless-architecture.md) for the complete current scope.

Phase 8 adds an isolated orchestration demonstration. It does not replace the primary
SNS/SQS/EventBridge choreography and it does not change the RabbitMQ project. The implementation can
be built and exercised entirely with PostgreSQL and LocalStack, using fake account
`000000000000` and no AWS account credentials.

## Purpose and boundary

The main architecture remains event choreography: publishers emit facts and independent consumers
react. This demonstration answers a different question: what changes when one component explicitly
owns the sequence and compensation policy?

```text
Step Functions Order Saga
    |
    +--> ReserveStock Lambda ------> saga_demo PostgreSQL schema
    |
    +--> ProcessPayment Lambda ----> saga_demo PostgreSQL schema
    |        |
    |        +--> approved --------> ConfirmOrder Lambda
    |        |
    |        +--> declined --------> CompensateStock Lambda
    |
    +--> technical payment error --> retry transient errors
                                  --> CompensateStock after retries are exhausted
```

Each task owns one local transaction. Step Functions does not create a distributed database
transaction and cannot roll back a transaction that another Lambda has committed. Compensation is a
new business operation: it locks the persisted reservation, restores the quantity, and records
`COMPENSATED` atomically.

## State-machine input and result

An execution receives:

```json
{
  "sagaId": "stable-workflow-id",
  "orderId": "stable-order-id",
  "productId": "prod-001",
  "quantity": 1,
  "amount": 129.99,
  "currency": "USD"
}
```

`sagaId` and `orderId` are stable idempotency keys. The state machine preserves the original input
and adds task results under `reservation`, `payment`, `confirmation`, or `compensation`. A handled
business decline ends with execution status `SUCCEEDED` because the workflow reached its intended
compensated terminal state. The domain result, rather than the Step Functions status alone, tells the
caller whether the Order was confirmed.

## States and decisions

1. `ReserveStock` decrements available stock and persists a `RESERVED` reservation in one
   transaction.
2. `ProcessPayment` requires that reservation and persists either `COMPLETED` or `FAILED`.
3. `PaymentApproved` is a `Choice` state. It routes approved payments to `ConfirmOrder` and business
   declines to `CompensateBusinessFailure`.
4. `ConfirmOrder` requires a completed payment and persists a `CONFIRMED` Saga Order.
5. `CompensateBusinessFailure` restores the reserved quantity after an expected decline.
6. `CompensateTechnicalFailure` restores it if transient Payment task errors still fail after retry.

The payment simulator deliberately matches the choreography demo: amounts greater than `1000.00`
fail with `AMOUNT_EXCEEDS_LIMIT`, amounts whose fractional part is `.13` fail with `CARD_EXPIRED`, and
other amounts succeed.

## Retry versus business failure

Expected payment declines are data: the Payment task returns `approved=false` and the `Choice` state
routes to compensation. Retrying a declined card would not change the outcome and could cause
unwanted provider calls.

The state machine retries only transient Lambda service errors:

- `Lambda.ServiceException`;
- `Lambda.AWSLambdaException`;
- `Lambda.SdkClientException`;
- `Lambda.TooManyRequestsException`.

It uses three attempts with exponential backoff. After the retry policy is exhausted, `Catch` stores
the workflow error and routes to technical compensation. This is intentionally different from SQS:
Step Functions owns state transitions and task retry policy, while an SQS/Lambda consumer is retried
through visibility timeout, receive count, and redrive.

## Persistence and idempotency

The separate `saga_demo` schema contains:

- `saga_inventory_products`, including the current stock quantity;
- `saga_stock_reservations`, unique by Saga and Order;
- `saga_payments`, unique by Saga and Order;
- `saga_orders`, unique by Saga and Order.

Every command first reads durable state. Repeating a task with the same `sagaId` returns the existing
result with `duplicate=true`. PostgreSQL uniqueness constraints protect the same invariants under
concurrency. Row locks serialize inventory updates and compensation. Compensation checks the current
reservation status so repeated compensation restores stock only once.

This is required even with an orchestrator. Lambda invocations and workflow tasks can be retried, and
a client can start another execution with the same business identifiers. Step Functions coordinates
the sequence; it does not provide exactly-once side effects.

## Handler responsibilities

The four handlers are explicit Java 17 `RequestHandler` implementations without Spring or a Lambda
framework:

| Handler | Input | Durable effect | Result |
|---|---|---|---|
| `ReserveStock` | Saga, Order, product, quantity | decrement stock and create reservation | reservation status and remaining stock |
| `ProcessPayment` | Saga, Order, amount, currency | persist completed or failed payment | approval and optional failure code |
| `ConfirmOrder` | Saga and Order | create confirmed Saga Order | `CONFIRMED` |
| `CompensateStock` | Saga, Order, reason | restore stock and mark reservation | `COMPENSATED` |

Invalid input, missing prerequisite state, unavailable PostgreSQL, and consistency violations are
task errors. Local Flyway initialization creates the schema on the first cold start. The same
database environment variables used by the other local handlers point these Lambdas at the Compose
PostgreSQL service.

## Choreography versus orchestration

| Concern | Main choreography | Phase 8 orchestration |
|---|---|---|
| Workflow knowledge | distributed among event producers and consumers | explicit in one state machine |
| Coupling | consumers depend mainly on event contracts | state machine depends on task interfaces and sequence |
| New consumer | can subscribe independently | usually requires a state-machine change if it is a workflow step |
| Compensation | emerges from additional events/handlers | visible as an explicit transition |
| Execution view | reconstructed from logs, events, and durable state | state-machine history shows the path |
| Availability | participants can progress independently | the orchestrator is part of the workflow control plane |
| Best fit | extensible reactions and fan-out | bounded multi-step workflows with explicit decisions |

Neither model is universally better. The primary commerce flow benefits from independent Payment,
Order, and Notification reactions. The Saga makes a reservation/payment/compensation sequence easier
to see and reason about, at the price of centralized workflow knowledge.

## Run locally with zero AWS cost

After configuring the LocalStack Hobby token described in the local guide:

```bash
bash ./scripts/bash/local/build.sh
bash ./scripts/bash/local/start.sh
bash ./scripts/bash/local/provision.sh
bash ./scripts/bash/local/saga-demo.sh
```

The demo starts four executions:

1. a successful payment that confirms an Order;
2. the same business Saga again, proving stock is not decremented twice;
3. a deterministic `CARD_EXPIRED` payment that compensates stock;
4. the same failed business Saga again, proving compensation is idempotent.

It verifies PostgreSQL state after each path. Local Terraform provisions only LocalStack resources at
`http://localhost:4566`; it does not use the AWS development root.

## What the local demonstration does not prove

LocalStack is useful for application integration but is not AWS. This exercise does not validate
real IAM enforcement, Step Functions service quotas, AWS regional behavior, CloudWatch execution
logging, distributed network latency, production Lambda scaling, or billing controls. AWS also
documents Step Functions Local as unsupported and without feature parity; LocalStack is a separate
emulator with its own compatibility boundary.

The workflow has one deliberately visible incompleteness: `ConfirmOrder` occurs after a successful
payment. If confirmation fails, this version does not refund the payment or compensate stock. A
production Saga would add a durable `RefundPayment` operation and define what happens if refund or
stock compensation itself fails. It would also need operational timeouts, alarms, replay policy, and
manual-resolution states.

The demo uses one PostgreSQL instance and schema to keep local learning inexpensive. Separate service
databases would make the distributed boundary more realistic, but would not change the central
lesson: each step commits locally and later failures require idempotent compensating operations.
