# Known Limitations

These limitations are intentional. This repository is an educational architecture comparison, not
a production-ready commerce platform.

## Notification creates durable records but does not deliver externally

`notification-demo-lambda` validates events and atomically persists a Notification record plus a
Notification `ProcessedEvent` in the separate `notification_domain` PostgreSQL schema. Unique
`eventId` constraints make repeated consumption durable and idempotent. It also writes structured
JSON logs.

It does not send email, SMS, webhook, or push messages. The stored `CREATED` row represents a durable
notification intent, not confirmed external delivery. A provider integration would require a
Delivery Outbox or equivalent durable dispatch state plus a stable provider idempotency key to handle
the crash window between the external call and the local delivery marker.

The `forceFailure=true` SNS/SQS message attribute intentionally fails valid demo messages so retries
and DLQ redrive can be observed. It is test transport metadata, not a domain event field.

## Outbox does not provide exactly-once publication

Phase 5 atomically persists Order state with Order Outbox and terminal Payment state with Payment
Outbox. AWS publication is deliberately outside those transactions. A publisher crash after SNS or
EventBridge accepts an event but before PostgreSQL records `PUBLISHED` causes republication.

Stable `eventId` values and idempotent consumers make that safe, but delivery remains at least once.
The educational implementation does not automatically archive published Outbox rows; retention and
purging policy belongs in a later operational phase. Phase 6 measures only outstanding rows, so old
`PUBLISHED` rows do not create false stale-Outbox alarms.

## Order command and Product consistency boundary

The default AWS development profile uses a deterministic, stateless Product simulator with two
catalog entries. It validates known products and a fixed availability ceiling but does not decrement
durable stock, coordinate concurrent reservations, or prove service-to-service networking. This is
intentional for the event-driven deployment demo. Set `product_adapter_mode = "HTTP"` and configure a
private Product endpoint when testing the original synchronous boundary.

In HTTP mode, Order synchronously reserves each item through Product REST before committing its local Order
transaction. Product and Order do not share a transaction. If a later item reservation or the Order
database commit fails, earlier stock reservations are not automatically compensated. The separate
Phase 8 Saga makes payment-failure compensation explicit; the primary REST flow still does not pretend
the calls are atomic.

Sequential HTTP retries with the same `Idempotency-Key` return the stored Order without another stock
call. A truly concurrent pair can both pass the initial lookup before the database unique constraint
selects a winner, so an extra Product reservation is still possible. Production handling would use a
durable request claim/lease or a Product-side reservation idempotency key.

The HTTP API uses `AWS_IAM` by default and rejects unsigned callers before invoking Lambda. This is
appropriate for a developer/operator demonstration but is not customer authentication. The signed
AWS principal is not mapped to `x-customer-id`; customer ID and email remain trusted test headers.
A production public/customer API would normally use JWT/Cognito or another end-user authorizer and
derive customer identity from verified claims. `NONE` remains configurable for an isolated dev demo
but Terraform rejects it when `environment = "prod"`.

## No exactly-once delivery

SNS, standard SQS, Lambda retries, and Outbox republication can produce duplicates and may
reorder events. Durable business consumers must use stable `eventId` values, local transactions,
and database uniqueness constraints. The design does not claim end-to-end exactly-once delivery.

The simulated gateway is deterministic but not an external provider. A real adapter must forward
the stable gateway idempotency key. A crash after a successful provider call and before the local
terminal transaction can otherwise cause another charge attempt on SQS redelivery.

## Educational database credentials and migrations

AWS dev uses the RDS-managed master secret, and Flyway runs during Lambda cold initialization. This
avoids committing or passing a password through Terraform, but the database role is broader than a
production runtime role. A production deployment should run Flyway separately and issue a restricted
application user.

RDS is single-AZ, permits destructive dev cleanup without a final snapshot, and has no RDS Proxy.
The Lambda pool and concurrency are deliberately bounded, but this is not a high-availability design.

## Reduced surrounding domain

The AWS variant does not duplicate the existing Product or Auth services. Order can call Product
through a configurable REST adapter, while the default development profile uses the deterministic
Product simulator. Test events use a known `customerId`; customer-facing authentication remains
outside the educational implementation.

## Observability boundaries

CloudWatch dashboards and alarms improve detection; they do not provide distributed tracing. A
stable `correlationId`, `eventId`, SQS message ID, and Lambda request ID allow manual log correlation,
but X-Ray/OpenTelemetry traces are not configured. Logs avoid full payloads and secrets, although
production deployments would still need retention, access control, masking, and audit policies.

Outbox metrics use CloudWatch Embedded Metric Format. They exist only after a scheduled publisher
has emitted a log event. Missing data is treated as healthy to avoid false alarms in an idle dev
environment, which means a completely disabled schedule is detected by EventBridge failure signals
only when invocation fails; there is no heartbeat/missing-publisher alarm yet.

The alarm SNS topic has no subscription by default. Terraform cannot decide who owns an email, SMS,
PagerDuty, or incident-management destination. Operators must add and confirm a destination after
deployment. CloudWatch custom metrics, dashboards, alarms, Logs Insights, and retained logs can incur
costs even when the application is otherwise idle.

## Development environment

The Terraform root remains optimized for one educational AWS environment at a time. Phase 7 separates
reviewed variable files and adds an expected-account guard, but it does not create AWS accounts,
bootstrap a remote state bucket, or supply ready-to-apply production values. It also does not include
custom KMS keys per resource, RDS Proxy, comprehensive CI/CD, or production on-call integrations.
AWS resources are not provisioned automatically and may incur charges when
the user applies Terraform.

The runtime still reads the RDS-managed master secret and all three domains share one PostgreSQL instance
through separate schemas. IAM restricts secret access to the database-using Lambdas, but database-level permissions are
broader than separate runtime roles and databases would provide. Phase 7 does not disguise that
application/database authorization limitation as an IAM solution.

## Step Functions Saga boundary

The Phase 8 Saga is provisioned only in the LocalStack Terraform root. It is an isolated learning
workflow and is not connected to the HTTP Order API or the primary SNS/SQS/EventBridge choreography.
Its four tasks share a separate `saga_demo` schema on the local PostgreSQL instance.

The demo compensates a failed or technically unsuccessful Payment task by restoring stock exactly
once. It does not yet implement `RefundPayment` if `ConfirmOrder` fails after Payment completed, nor a
manual-resolution path if compensation itself repeatedly fails. Production orchestration would need
those states, execution timeouts, alarms, and an explicit redrive/recovery policy.

Step Functions coordinates retries and transitions but does not provide distributed transactions or
exactly-once side effects. Task idempotency and database constraints remain necessary. LocalStack does
not prove real IAM enforcement, service quotas, AWS scaling, or CloudWatch execution-history behavior.
