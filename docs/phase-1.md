# Phase 1: Minimal OrderCreated Fan-Out

> **Historical phase snapshot.** This document describes the repository at the end of Phase 1, not
> the current implementation. Later phases added durable persistence, payment-result routing,
> Transactional Outboxes, observability, infrastructure hardening, and the isolated Saga. See the
> [main README](../README.md) and [current architecture](aws-serverless-architecture.md) for the final state.

## Objective

Demonstrate the managed AWS equivalent of publishing one `OrderCreated` event for multiple
independent consumers. Phase 1 is intentionally transport-only.

## Resources

| Resource | Purpose |
|---|---|
| SNS `order-events` topic | Publishes one event to multiple subscriptions |
| Payment OrderCreated queue | Buffers events independently for Payment |
| Payment OrderCreated DLQ | Isolates messages Payment cannot process |
| Notification OrderCreated queue | Buffers events independently for the demo consumer |
| Notification OrderCreated DLQ | Isolates messages the demo consumer cannot process |
| Payment Lambda | Validates and logs the Payment copy of the event |
| Notification Demo Lambda | Validates the event and writes structured JSON logs only |
| Two CloudWatch log groups | Stores function logs for 14 days |

## Handler contract

Both functions implement the Java Lambda `RequestHandler<SQSEvent, SQSBatchResponse>` interface.

Input:

- an SQS batch;
- each SQS body is the raw `OrderCreated` JSON published to SNS;
- `ApproximateReceiveCount` is read from SQS attributes for diagnostics.

Output:

- `SQSBatchResponse`;
- valid records are omitted from `batchItemFailures`;
- invalid records are returned by SQS `messageId`.

Errors:

- malformed JSON;
- missing required contract fields;
- unexpected `eventType`;
- non-positive total or empty items.

Successful records in the same batch are not retried when another record is invalid because
the event-source mapping enables `ReportBatchItemFailures`.

The Notification Demo additionally treats the SQS/SNS string message attribute
`forceFailure=true` as an intentional record failure. This switch exists only to exercise retries
and DLQ redrive with a valid domain event; it is not part of `OrderCreated`.

## Retry model

The Lambda does not delete SQS messages directly and does not simulate RabbitMQ acknowledgements.

```text
Valid record
  -> handler omits it from batch failures
  -> Lambda deletes it from SQS

Invalid record
  -> handler returns its messageId as failed
  -> message remains in SQS but invisible for 90 seconds
  -> message becomes visible and is received again
  -> after five receives, SQS moves it to that queue's DLQ
```

Default settings:

| Setting | Value | Reason |
|---|---:|---|
| Lambda timeout | 15 seconds | Enough for transport-only validation |
| Queue visibility timeout | 90 seconds | Six times the Lambda timeout |
| `maxReceiveCount` | 5 | Allows transient failures before isolation |
| Batch size | 5 | Keeps partial-failure behavior easy to inspect |
| Maximum concurrency | 2 | Bounds cost and prepares for later database limits |
| DLQ retention | 14 days | Gives time for diagnosis and redrive |

All source queues and DLQs explicitly enable SQS-managed server-side encryption.

## IAM boundaries

SNS receives permission through each SQS queue's resource policy. The policy permits only:

```text
Principal: sns.amazonaws.com
Action: sqs:SendMessage
Condition: aws:SourceArn equals the order-events topic ARN
```

Each Lambda execution role can:

- receive, delete and change visibility only on its own source queue;
- read only its own queue attributes;
- write only to its own CloudWatch log group.

The functions cannot publish SNS messages, consume the other function's queue, access a DLQ,
or access a database.

## Notification Demo boundary

The Notification consumer is not a production notification service. It has no PostgreSQL schema,
entity, repository, `processed_events` table, SMTP credentials, email templates, delivery states,
or resend workflow. It validates `OrderCreated` and writes JSON to CloudWatch Logs.

Because logging is its only effect, it intentionally has no persistent idempotency. At-least-once
delivery may produce a duplicate log entry for the same `eventId`. This is acceptable for the demo
and must not be copied to a consumer that sends email or performs another external side effect.

## Raw SNS delivery

The SQS subscriptions enable raw message delivery. Therefore the SQS body is the event contract
itself rather than an SNS notification envelope containing a second encoded JSON string.

This keeps the messaging contract independent of SNS while the SQS transport metadata remains
available in the outer Lambda `SQSEvent`.

## Phase boundary

Phase 1 proves:

- SNS fan-out;
- independent consumer queues;
- independent failure isolation;
- Lambda polling through SQS event-source mappings;
- partial batch failure reporting;
- CloudWatch logging;
- least-privilege transport IAM.

Phase 1 does not claim:

- payment processing;
- durable consumer idempotency;
- real notification delivery or Notification persistence;
- PostgreSQL persistence;
- EventBridge payment-result routing;
- Transactional Outbox publication.
