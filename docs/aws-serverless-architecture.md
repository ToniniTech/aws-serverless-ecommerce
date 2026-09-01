# AWS Serverless Architecture

This document describes the implemented event choreography and the isolated local Step Functions
orchestration demonstration. The latter is a comparison, not a replacement for the primary flow.

## 1. Original RabbitMQ architecture

The original repository contains five Spring Boot services with one MySQL database per service.
Order Service calls Product Service synchronously to obtain authoritative price and decrease
stock. It saves the Order and an Outbox record in one local transaction. An outbox processor
publishes `OrderCreated` to RabbitMQ, where Payment and Notification have independent queues.

Payment publishes `PaymentProcessed` or `PaymentFailed`. Order consumes those events to update
order state, while Notification consumes them only to notify the customer.

The RabbitMQ implementation remains in its original repository and is not modified by this project.

## 2. AWS architecture

Deployment-readiness D2 retains the Phase 5 business flow, Phase 6 visibility, Phase 7 hardened
modular IaC, and D1 Product simulation/query work. It adds SigV4-based `AWS_IAM` authorization to
both HTTP API routes by default.

```text
HTTP API --> Order Lambda --> Product port --> SIMULATED (default) or HTTP
                +--> Order + Items + OrderOutbox --> scheduled publisher --> SNS order-events
                      +--> payment-order-created-queue --> Payment Lambda
                      |       +--> Payment + ProcessedEvent + PaymentOutbox
                      |               +--> scheduled publisher --> EventBridge payment-events
                      |                       +--> order-payment-result-queue --> Order result Lambda
                      |                       +--> notification-payment-result-queue --> Notification Lambda
                      +--> notification-order-created-queue --> Notification Lambda
                                                                            +--> Notification + ProcessedEvent

HTTP API GET /orders/{orderId} --> Order Query Lambda --> Order PostgreSQL schema
```

The approved revised roadmap combines Payment and PostgreSQL in Phase 2/3, adds EventBridge and
Order result handling in Phase 4, adds both Transactional Outboxes in Phase 5, adds focused
observability in Phase 6, adds Terraform modularization and IAM hardening in Phase 7, and ends with an isolated minimal Step
Functions Saga demonstration in Phase 8.

The Product boundary remains synchronous by design. `SIMULATED` changes only the adapter behind the
domain port so the asynchronous AWS flow can be deployed without hosting Product Service. `HTTP`
retains the real REST comparison. The simulator is stateless and is not evidence of correct stock
concurrency or compensation.

## 3. Conceptual equivalences

| RabbitMQ concept | AWS concept | Important qualification |
|---|---|---|
| Queue | SQS queue | SQS is managed and uses visibility timeouts rather than channel acknowledgements |
| Fan-out/topic exchange | SNS topic with SQS subscriptions | Each subscription needs its own durable queue for independent consumption |
| Routing by event type | EventBridge rule | EventBridge matches structured event patterns and is not a RabbitMQ exchange clone |
| Consumer service | Lambda | Lambda scales by invocation and has runtime, timeout and concurrency limits |
| Retry and DLQ | SQS visibility, receive count and redrive DLQ | Retry timing is based on visibility, not an application `basicNack()` call |
| Orchestrated Saga | Step Functions | The state machine explicitly knows workflow order and compensation |

## 4. Where there is no one-to-one equivalence

Lambda's SQS integration polls queues on the application's behalf. On successful processing,
Lambda deletes the records. On failure, records remain hidden until the visibility timeout expires.
Application code should not imitate `basicAck()` or `basicNack()`.

SNS is optimized for publication and fan-out. SQS owns buffering and consumer retry. EventBridge
is used for content-based routing of payment results. Using all three has a domain reason;
they are not interchangeable decorations.

## 5. Delivery semantics

The design assumes at-least-once delivery and possible reordering. Standard SQS queues can deliver
a message more than once. Lambda retries and publisher crash windows can also produce duplicates.
The application never claims end-to-end exactly-once delivery.

## 6. Idempotency

Payment persists `eventId` in `processed_events`, and PostgreSQL enforces unique `order_id`,
`source_event_id`, and gateway idempotency keys. Terminal Payment state and the processed marker
commit in one local PostgreSQL transaction.

Payment enforces one payment per order and uses a stable gateway idempotency key. Payment result
events use a stable event ID derived from the persisted payment ID.

Order persists result `eventId` in `order_processed_events`. It locks the Order row, guards the
`PENDING -> PAID/FAILED` transition, and commits the state change and processed marker atomically.
Notification persists a durable notification intent and its consumer `ProcessedEvent` in one local
transaction. Unique `eventId` constraints absorb duplicate delivery. It still does not claim that an
external email or SMS has been delivered exactly once.

## 7. Transactional Outbox

The current Order atomic boundary is:

```text
Order PostgreSQL transaction = Order + OrderItems + OrderOutbox
```

It is not `PostgreSQL + SNS`.

The current Payment atomic boundary is:

```text
Payment PostgreSQL transaction = terminal Payment result + ProcessedEvent + PaymentOutbox
```

Scheduled publisher Lambdas claim bounded rows, commit the claims, call SNS or EventBridge, then mark
successful rows `PUBLISHED`. Neither atomic boundary includes AWS. They are not `PostgreSQL + SNS` or
`PostgreSQL + EventBridge` transactions.

Outbox publication can be repeated after a crash, so downstream idempotency remains mandatory. Claim
queries use `FOR UPDATE SKIP LOCKED` so concurrent workers do not wait on or claim the same row. Locks
are released before network I/O. A claim lease recovers abandoned `PROCESSING` rows, and failed rows
return to `PENDING` with bounded exponential backoff.

## 8. Eventual consistency

Order creation returns after synchronous Product reservations and the local Order/Outbox commit, but
before Payment completes and Notification persists its durable intent.
Queue depth, Lambda concurrency, retries and downstream availability determine propagation delay.
Clients must tolerate a pending order while asynchronous work is in progress.

The synchronous Order-to-Product REST call remains deliberate. It preserves authoritative price
and stock validation but also leaves a distributed failure boundary that a local Order transaction
cannot roll back.

## 9. Retries

The AWS development queues use visibility timeouts chosen to exceed their Lambda timeouts and five
receives before their independent DLQs. Consumers use partial batch responses and bounded
concurrency. The local profile uses a 30-second visibility timeout and three receives so resilience
exercises finish quickly. These values should be tuned from measured database and gateway latency.

## 10. Dead-letter queues

Each important consumer flow owns a separate redrive DLQ. This prevents a failing Notification
message from contaminating Payment diagnostics. EventBridge target-delivery DLQs, introduced only
if needed, are distinct from SQS consumer redrive DLQs because they represent different failures.

## 11. Observability

All consumers write structured JSON with `eventId`, `correlationId`, `orderId`, Lambda request ID,
SQS message ID, and receive count when those values exist. Payment additionally records Payment
status, duplicate decisions, and the stable gateway key. Secrets, credentials, customer email, and
full event payloads are not logged.

Scheduled Outbox publishers emit CloudWatch Embedded Metric Format records. CloudWatch extracts
claimed, published, failed, and oldest-outstanding-age metrics from their existing log groups, so the
publisher roles do not need `cloudwatch:PutMetricData`. Only the low-cardinality `Publisher` value is
a metric dimension; `eventId` and `correlationId` stay searchable log fields rather than creating an
unbounded custom-metric series.

The Phase 6 dashboard combines source-queue age, DLQ depth, Lambda errors/throttles/duration, Outbox
health, and RDS CPU/connections. Alarms cover delayed source queues, non-empty DLQs, Lambda runtime
errors, application errors, throttles, EventBridge failed target invocations, API 5xx responses, and
stale/failed Outbox publication.

SQS partial-batch responses are important: returning a record in `batchItemFailures` is a successful
Lambda invocation, so it does not increment the native `AWS/Lambda Errors` metric. Structured ERROR
log metric filters provide the immediate application signal; queue age and DLQ alarms show sustained
or exhausted retries.

## 12. Operational trade-offs

AWS removes broker installation, patching and capacity management, but introduces service-specific
delivery behavior, IAM, per-request pricing, concurrency controls and distributed CloudWatch views.
RabbitMQ offers more direct control over exchanges, channels and acknowledgements. The managed AWS
design trades that control for elastic operation and reduced broker administration.

The serverless design requires careful database connection limits. Payment and Order currently use
two-connection pools with maximum concurrency of two. That protects the small dev RDS instance but
also limits throughput; unlimited Lambda concurrency and a relational database are not safe defaults.

Phase 7 keeps service composition in the environment root while extracting repeated lifecycle units:
an SQS source/DLQ/redrive module and an observability module. Networking and RDS remain explicit
because their security groups, endpoint policies, database secret, topics, and event bus form real
cross-service dependencies; hiding them behind one broad module would reduce clarity rather than
create a reusable boundary.

Queue policies now require the exact SNS/EventBridge source ARN and AWS account. Private endpoint
policies name only the Lambda roles that need each service. Lambda ENI permissions retain
`Resource: *` because those EC2 actions do not support useful resource-level scoping; this is an AWS
IAM limitation, not a general wildcard policy.

The Order HTTP API uses `AWS_IAM` by default. API Gateway validates the SigV4 request and the caller's
route-scoped `execute-api:Invoke` permission before Lambda runs. This authenticates an AWS workload or
developer identity; it does not turn trusted customer headers into verified end-user identity. The
configuration can use `NONE` for an isolated demonstration, but production validation forbids it.

## 13. Choreography versus orchestration

The primary design is choreography: components react independently to SNS and EventBridge events.
No component owns the complete workflow.

The Phase 8 Step Functions demonstration is orchestration: a state machine explicitly coordinates
`ReserveStock`, `ProcessPayment`, `ConfirmOrder`, and `CompensateStock`. It remains separate so both
approaches can be compared without replacing the main flow. The task implementations use durable,
idempotent PostgreSQL state; compensation restores a persisted reservation rather than merely logging.

A payment business decline is a successful task result routed by a `Choice`. Transient Lambda service
errors are retried and then caught for compensation. The orchestrator does not create a distributed
transaction or exactly-once side effects. See [Phase 8](phase-8-step-functions-saga.md) for the state
contract, failure model, and local exercise.

## 14. Revised scope boundaries

- Notification durably records notification intent and consumer idempotency in PostgreSQL, but still
  has no SMTP/SMS provider, delivery confirmation, or resend workflow.
- Payment is the principal durable idempotent consumer and receives PostgreSQL directly in Phase 2/3.
- Order calls Product synchronously through a `ProductInventoryPort`; an AWS Product service is not duplicated.
- Basic AWS caller authentication is included; end-user identity/JWT handling remains outside the main learning path.
- Phase 5 implements complete Order and Payment Outboxes because they protect the critical dual-write boundaries.
