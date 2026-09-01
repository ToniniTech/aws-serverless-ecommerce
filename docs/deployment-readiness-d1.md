# Deployment Readiness D1: Product Profile and Order Query

> **Historical readiness snapshot.** This document records the D1 checkpoint. D2 subsequently added
> configurable API authorization and D3 recorded a build and plan review. No AWS resources were
> applied. See the [main README](../README.md) for current deployment status.

## Goal

D1 removes two blockers to an affordable end-to-end demonstration without changing the event-driven
business flow:

1. Order creation can use a deterministic Product simulator instead of requiring a hosted Product
   Service.
2. The final eventual Order state can be read through `GET /orders/{orderId}`.

This is not an AWS deployment and does not introduce API authorization. Those are separate approval
gates.

## Product profiles

`PRODUCT_ADAPTER_MODE` selects the adapter behind `ProductInventoryPort`:

| Mode | Behavior | Intended use |
|---|---|---|
| `SIMULATED` | Validates a fixed in-memory catalog and returns deterministic name/price data | Low-cost AWS flow demonstration |
| `HTTP` | Calls `PATCH /api/products/{productId}/decreaseStock` synchronously | Full RabbitMQ/AWS boundary comparison |

Terraform defaults development to `SIMULATED`. The Java runtime defaults to `HTTP` when the variable
is absent, preventing an existing HTTP invocation from silently changing behavior. Terraform rejects
`HTTP` mode without `product_service_base_url` and creates Product network egress only in HTTP mode.

The simulator recognizes:

| Product ID | Name | Unit price | Demonstration availability ceiling |
|---|---|---:|---:|
| `prod-001` | Mechanical Keyboard | 129.99 | 10 |
| `prod-002` | Wireless Mouse | 49.90 | 25 |

It is stateless: successful calls do not decrement stock. It is a boundary simulator, not an inventory
service and not a concurrency test.

## Order query Lambda

Handler: `com.ecommerce.serverless.order.OrderGetHandler::handleRequest`

Input: API Gateway HTTP API v2 request with `orderId` as a path parameter.

Output:

- `200` with Order status, amount, currency, optimistic version, payment outcome fields, timestamps,
  and items;
- `400` when the path parameter is missing;
- `404` when the Order does not exist;
- `500` for an unexpected persistence/runtime failure.

The response intentionally excludes customer email and customer ID. A single SQL `LEFT JOIN` reads
the Order and items as one database statement. The Lambda has its own role, log group, concurrency
limit, and API integration. IAM allows only the RDS-managed secret, its own logs, and Lambda VPC
network-interface operations; it has no SNS, SQS, or EventBridge permissions.

Structured CloudWatch logs contain the Order ID, status when available, Lambda request ID, and error
type. They do not contain customer PII or the full response.

## Flow to verify after an approved deployment

```text
POST /orders
  -> Product simulator
  -> Order + OrderOutbox transaction
  -> SNS -> SQS -> Payment Lambda
  -> Payment + PaymentOutbox transaction
  -> EventBridge -> SQS -> Order result Lambda
  -> PENDING becomes PAID or FAILED

GET /orders/{orderId}
  -> Order Query Lambda
  -> current PostgreSQL projection
```

The GET endpoint is a snapshot of eventual state. A `PENDING` response immediately after POST is
normal; clients should poll with a bounded delay rather than assume synchronous payment completion.

## Local and static verification

```powershell
.\mvnw.cmd clean verify
terraform -chdir=infrastructure/terraform/dev fmt -check -recursive
terraform -chdir=infrastructure/terraform/dev validate
terraform -chdir=infrastructure/terraform/modules/sqs-redrive-flow test
terraform -chdir=infrastructure/terraform/modules/observability test
```

Integration tests use Testcontainers when Docker is available. Unit tests cover deterministic Product
success/failure and Order query HTTP responses. The JDBC integration test verifies that persisted
Order and item data can be reconstructed as a projection.

## Trade-offs

- The simulator removes Product hosting and networking cost, but it cannot demonstrate real stock
  concurrency, compensation, or service failure behavior.
- A separate query Lambda provides a clear read responsibility and narrower IAM, but adds another
  cold-start/runtime unit.
- The query uses the same RDS instance and master secret as the educational runtime. A production
  system should use a read-limited database role and separately managed migrations.
- The API remains unauthenticated during D1. It must not be presented as production-secure.

## Deployment-readiness progression after D1

1. D2 subsequently added configurable API Gateway `AWS_IAM` authorization and documented signed requests.
2. D3 subsequently built artifacts, initialized Terraform, validated the selected environment, and
   recorded a saved-plan review without applying it.
3. D4 remains unexecuted and requires a fresh reviewed plan plus explicit approval before apply.
4. D5 remains unexecuted and would run successful and failed end-to-end smoke tests using POST and
   bounded GET polling.
5. D6 remains unexecuted and would exercise duplicate publication, transient Outbox failure, SQS
   retry, and DLQ redrive.

Phase 8 subsequently added a separate LocalStack Saga demonstration. It remains isolated from the
core choreography and does not imply that D4-D6 have been completed.
