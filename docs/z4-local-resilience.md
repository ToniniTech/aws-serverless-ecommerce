# Z4 Local Resilience Exercises

Z4 hardens the asynchronous flow without deploying to AWS. Every command targets Docker,
PostgreSQL, and LocalStack at `http://localhost:4566` using fake account `000000000000`.

## Scenario matrix

| Scenario | Injected condition | Expected durable result |
|---|---|---|
| Business failure | Order total exceeds the simulated payment limit | Payment `FAILED`, Order `FAILED`, `PAYMENT_FAILED` notification |
| Duplicate result | The same `PaymentFailed.eventId` is sent to EventBridge again | Order version and all consumer row counts remain unchanged |
| Outbox transport failure | Order publisher temporarily targets a nonexistent local SNS topic | Row returns to `PENDING`, records the error, then becomes `PUBLISHED` on retry |
| Consumer exhaustion | Notification receives `forceFailure=true` | No database effect; SQS retries and redrives to the dedicated DLQ |

These scenarios test at-least-once behavior. They do not claim exactly-once delivery.

## Complete failure path

`failure-path.ps1` creates eight simulated keyboards. The total exceeds the deterministic payment
limit while remaining within simulated stock, so the business outcome is predictable:

```text
OrderCreated
  -> Payment FAILED / AMOUNT_EXCEEDS_LIMIT
  -> Payment Outbox
  -> EventBridge PaymentFailed
     +-> Order FAILED, version 1
     +-> durable PAYMENT_FAILED Notification
```

The script republishes the identical Payment Outbox payload through EventBridge. Both SQS consumers
run again, but the stable `eventId` and PostgreSQL uniqueness constraints prevent another business
effect. A business decline is successfully handled; it is not a retryable infrastructure error.

## Outbox recovery

`outbox-recovery-test.ps1` changes only the emulated Order Outbox Lambda environment and always
restores it in `finally`. The first publisher invocation calls a syntactically valid but nonexistent
local SNS topic. The processor releases the claimed row with:

```text
status = PENDING
attempt_count = 1
last_error = present
```

After restoring the real local topic, the second claim publishes successfully:

```text
status = PUBLISHED
attempt_count = 2
```

The count is two because it records publication attempts, not failures. PostgreSQL and SNS are not
one atomic transaction. The Outbox protects the event during the outage; idempotent consumers protect
the later republication window.

## Lambda, SQS retry, and DLQ

`consumer-dlq-test.ps1` places a valid `OrderCreated` record on the Notification source queue with the
test-only SQS message attribute `forceFailure=true`. Notification returns that record in
`batchItemFailures`. Lambda's event-source mapping therefore does not delete it. SQS hides it for the
visibility timeout, makes it available again, increments its receive count, and moves it to the
dedicated DLQ after the configured maximum.

The exercise temporarily shortens only the local queue visibility timeout and restores it in
`finally`. The failed record creates neither a Notification nor a ProcessedEvent because it fails
before the database transaction.

This is the AWS model to compare with RabbitMQ:

```text
RabbitMQ: consumer calls ACK/NACK
AWS: Lambda integration interprets the batch response; SQS owns visibility, retry count, and redrive
```

Application code does not call an SQS equivalent of `basicAck()`.

## Run

Start and provision the local environment first:

```powershell
./scripts/local/build.ps1
./scripts/local/start.ps1
./scripts/local/provision.ps1
```

Run all resilience scenarios:

```powershell
./scripts/local/resilience-suite.ps1
```

Or run them separately:

```powershell
./scripts/local/failure-path.ps1
./scripts/local/outbox-recovery-test.ps1
./scripts/local/consumer-dlq-test.ps1
```

## Production boundary

The same failure reasoning transfers to AWS, but LocalStack does not validate AWS IAM enforcement,
managed polling/scaling, regional failures, service quotas, production latency, billing alarms, or
exact CloudWatch behavior. A future controlled AWS smoke test should focus on those cloud-only
properties rather than rediscovering application defects.
