# Phase 6: CloudWatch Observability

> **Historical phase snapshot.** This document describes the observability increment introduced in
> Phase 6. Phase 7 subsequently modularized and hardened the Terraform configuration. See the
> [main README](../README.md) and [current architecture](aws-serverless-architecture.md) for the final state.

Phase 6 adds detection and investigation tools without changing the Phase 5 business flow. Terraform
creates the resources, but this phase does not run `terraform apply` or subscribe a real person.

## Signals and why they exist

| Signal | Source | What it detects |
|---|---|---|
| Source queue oldest age | Native SQS metric | A consumer is falling behind or repeatedly retrying |
| DLQ visible messages | Native SQS metric | Retry policy was exhausted and operator action is required |
| Lambda errors | Native Lambda metric | An invocation escaped with an unhandled error |
| Application errors | Structured-log metric filter | Per-record failures returned through SQS partial batch response |
| Lambda throttles | Native Lambda metric | Reserved/account concurrency prevented invocation |
| EventBridge failed invocations | Native EventBridge metric | A rule could not deliver to its target |
| Order API 5xx | Native API Gateway metric | The synchronous order endpoint failed server-side |
| Outbox failed/oldest outstanding | EMF custom metrics | AWS publication failures or unpublished rows becoming stale |
| RDS CPU/connections | Native RDS metrics | Database pressure relevant to bounded Lambda concurrency |

The distinction between Lambda and application errors matters. An SQS handler that returns one
`batchItemFailure` has successfully completed from Lambda's perspective. The message remains for
retry, but `AWS/Lambda Errors` stays zero. Phase 6 therefore alarms on structured `level=ERROR` logs
as well as queue delay and DLQ depth.

## Structured correlation

Business-consumer logs contain the values available at that boundary:

- `eventId` for idempotency and replay identity;
- `correlationId` for the end-to-end Order flow;
- `orderId` and, for payment results, `paymentId`;
- `sqsMessageId` and `receiveCount` for transport diagnosis;
- `awsRequestId` for the exact Lambda invocation.

The Order HTTP handler also records its Lambda request and correlation IDs. It never logs request
bodies, credentials, customer email, database secrets, or full event payloads.

## Outbox Embedded Metric Format

Each publisher queries the oldest `PENDING` or `PROCESSING` row after its bounded batch and emits:

- `OutboxClaimed`;
- `OutboxPublished`;
- `OutboxFailed`;
- `OutboxOldestOutstandingAgeSeconds`.

The namespace defaults to `serverless-ecommerce/dev`. `Publisher` is the only dimension. Event IDs
are intentionally not dimensions because every unique value would create another billable metric
time series. EMF is written through the normal Lambda logger, so publisher IAM remains limited to
its log group and business destination; `cloudwatch:PutMetricData` is unnecessary.

An oldest age of zero means no outstanding row remains. Published-row retention does not affect this
metric. The extra `MIN(created_at)` query is bounded in result size but PostgreSQL must inspect the
outstanding subset; the existing status/created-time index supports that educational workload.

## Dashboard and alarms

Terraform creates `${project_name}-${environment}-workflow` and one operational SNS topic. Defaults:

- source queue age: 300 seconds for two consecutive one-minute periods;
- oldest outstanding Outbox row: 300 seconds for two consecutive periods;
- any visible DLQ message, publication failure, Lambda/application error, throttle, EventBridge
  failed invocation, or API 5xx alarms immediately;
- missing data is `notBreaching`, appropriate for an idle development environment.

The SNS topic deliberately has no subscription. After an approved deployment, connect and confirm a
destination owned by the operator. Alarm recovery notifications are enabled for queue-age, DLQ, and
Outbox-age alarms; high-frequency transient signals notify only on entry to ALARM.

## Investigation with Logs Insights

Choose the relevant Lambda log groups and use these queries.

Trace one Order flow:

```text
fields @timestamp, level, message, eventId, correlationId, orderId, paymentId,
       sqsMessageId, receiveCount, awsRequestId
| filter correlationId = "corr-phase-6"
| sort @timestamp asc
```

Inspect failures and retries:

```text
fields @timestamp, consumer, handler, publisher, message, errorType, error,
       eventId, correlationId, orderId, sqsMessageId, receiveCount, awsRequestId
| filter level = "ERROR"
| sort @timestamp desc
| limit 100
```

Inspect Outbox batches:

```text
fields @timestamp, Publisher, OutboxClaimed, OutboxPublished, OutboxFailed,
       OutboxOldestOutstandingAgeSeconds, awsRequestId
| filter ispresent(Publisher)
| sort @timestamp desc
```

## Verification and safe alarm exercises

Local verification does not require AWS:

```powershell
.\mvnw.cmd clean verify
.\.tools\terraform-1.15.8\terraform.exe fmt -check -recursive infrastructure\terraform\dev
.\.tools\terraform-1.15.8\terraform.exe -chdir=infrastructure\terraform\dev validate
```

After a separately approved AWS apply:

1. Subscribe an owned endpoint to `operational_alarm_topic_arn` and confirm it.
2. Create an Order with a known `x-correlation-id` and follow it through Logs Insights.
3. Use the documented Notification `forceFailure=true` transport attribute to observe retry, source
   queue age, application-error, and eventually DLQ alarms.
4. Make an Outbox destination temporarily unavailable only in a disposable environment to observe
   `OutboxFailed`, retry backoff, oldest-row age, and recovery.
5. Redrive a DLQ only after correcting the cause; redrive can repeat business delivery and therefore
   still relies on consumer idempotency.

Do not test alarms by deleting queues, disabling production destinations, or changing credentials.

## Trade-offs and limits

- Alarms and custom metrics have AWS cost; thresholds are educational starting points, not SLOs.
- There is no X-Ray/OpenTelemetry distributed trace. Correlation is log-based.
- Missing EMF data is healthy by default, so a fully silent publisher needs a future heartbeat alarm.
- Approximate SQS metrics can lag and are not transactionally synchronized with Lambda logs.
- The dashboard aids diagnosis but is not an incident-response process.
- Phase 7 subsequently adds Terraform modules, environment separation, finer IAM/networking,
  state-migration declarations, and broader operational hardening.
