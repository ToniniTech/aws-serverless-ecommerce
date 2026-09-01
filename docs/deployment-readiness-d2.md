# Deployment Readiness D2: Configurable AWS IAM API Authorization

> **Historical readiness snapshot.** This document records the D2 authorization checkpoint. D3 was
> subsequently completed as a build and plan review, without applying AWS resources. See the
> [main README](../README.md) for current deployment status.

## Goal

D2 protects both Order HTTP API routes without introducing a customer identity platform:

- `POST /orders`
- `GET /orders/{orderId}`

The default is `AWS_IAM`. API Gateway verifies an AWS Signature Version 4 request and evaluates the
caller's `execute-api:Invoke` permission before invoking either Lambda.

## Configuration

```hcl
order_api_authorization_type = "AWS_IAM"
```

Accepted values are:

| Value | Behavior | Use |
|---|---|---|
| `AWS_IAM` | Requires SigV4 and caller IAM permission | Default AWS development profile |
| `NONE` | Accepts unsigned requests | Short-lived isolated demonstration only |

Terraform rejects `NONE` when `environment = "prod"`. Both routes always receive the same mode so a
deployment cannot accidentally protect creation while leaving Order status public.

## Caller permissions

This project deliberately does not create a user, access key, or generic demo role. The human or CI
identity used for the demonstration is owned outside this application and should receive only these
route resources, available from `terraform output order_api_invoke_arns`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "InvokeOrderDemoRoutes",
      "Effect": "Allow",
      "Action": "execute-api:Invoke",
      "Resource": [
        "arn:aws:execute-api:REGION:ACCOUNT:API_ID/*/POST/orders",
        "arn:aws:execute-api:REGION:ACCOUNT:API_ID/*/GET/orders/*"
      ]
    }
  ]
}
```

Use a temporary AWS SSO/profile session or an assumed role. Do not create long-lived access keys for
this demonstration and never put credentials in Terraform variables, shell scripts, `.env`, or Git.

## Signed invocation

`awscurl` is one convenient client because it signs an ordinary HTTP request using the standard AWS
credential chain:

```powershell
$api = terraform -chdir=infrastructure/terraform/dev output -raw order_api_endpoint
$region = "sa-east-1"
$profile = "your-temporary-profile"
$body = Get-Content examples/create-order.json -Raw

$response = awscurl --service execute-api --region $region --profile $profile `
  -X POST -H "content-type: application/json" -H "x-customer-id: customer-001" `
  -H "x-customer-email: customer@example.com" -H "x-correlation-id: corr-d2" `
  -H "idempotency-key: request-d2-001" --data $body "$api/orders"

$created = $response | ConvertFrom-Json
awscurl --service execute-api --region $region --profile $profile `
  "$api/orders/$($created.orderId)"
```

An unsigned request or a signed identity without the route permission is rejected by API Gateway and
does not invoke the Lambda. Exact error status/body should be treated as gateway behavior rather than
an application contract.

## Security boundaries

There are three different roles involved:

1. The caller identity has `execute-api:Invoke` for the two routes.
2. API Gateway has resource-based permission to invoke each specific Lambda route integration.
3. Each Lambda execution role has only its database secret, logs, VPC networking, and any required
   downstream permissions.

Granting a caller `execute-api:Invoke` does not grant Lambda, RDS, SNS, SQS, or EventBridge access.
Likewise, a Lambda execution role is not a client identity for this API.

`AWS_IAM` verifies an AWS principal, not an e-commerce customer. The current handlers still trust
`x-customer-id` and `x-customer-email`; a customer-facing version must derive these from validated JWT
claims or another end-user identity system.

## Observability

API access logs retain request ID, route, method, response status, source IP, IAM user ARN when
available, integration error, and response length. They do not record Authorization headers,
credentials, request bodies, customer email, or event payloads.

## Verification before deployment

```powershell
terraform -chdir=infrastructure/terraform/dev fmt -check -recursive
terraform -chdir=infrastructure/terraform/dev validate
terraform -chdir=infrastructure/terraform/modules/sqs-redrive-flow test
terraform -chdir=infrastructure/terraform/modules/observability test
```

After an approved deployment, verify both negative and positive cases:

1. unsigned POST is rejected before Lambda;
2. signed caller without `execute-api:Invoke` is rejected;
3. approved signed caller can create and query an Order;
4. the caller cannot invoke unrelated API routes;
5. CloudWatch API access logs contain no credentials or customer email.

## Trade-offs

- `AWS_IAM` is simple for developers, CI, and service-to-service callers already using AWS identities.
- SigV4 is less convenient for browsers and public customers than JWT/OIDC authentication.
- Route-scoped identity policies improve least privilege but caller-role lifecycle remains an external
  platform responsibility.
- Configurable `NONE` keeps a low-friction learning mode, but it must never be confused with a secure
  public deployment.

## Subsequent gate

D3 subsequently built and packaged the source at that checkpoint, verified the selected AWS account
and environment, initialized Terraform, and produced a saved plan for human review. It did not apply
that plan. The historical result is recorded in [Deployment Readiness D3](deployment-readiness-d3.md).
