# Phase 7: Terraform Modules, Environments, and IAM Hardening

> **Historical phase snapshot.** This document describes the infrastructure hardening completed in
> Phase 7. Phase 8 and deployment-readiness work were added later without replacing these module and
> IAM boundaries. See the [main README](../README.md) and
> [current architecture](aws-serverless-architecture.md) for the final state.

Phase 7 changes infrastructure organization and guardrails. It does not change the Order, Payment,
Notification, Outbox, SNS/SQS, or EventBridge business flow, and it does not run `terraform apply`.

## Module boundaries

`modules/sqs-redrive-flow` owns one standard encrypted source queue, its dedicated encrypted DLQ,
redrive policy, redrive-allow policy, and sender resource policy. The policy requires:

- one declared AWS service principal (`sns.amazonaws.com` or `events.amazonaws.com`);
- exact topic/rule source ARNs;
- the expected source AWS account.

It deliberately does not own Lambda event-source mappings or SNS/EventBridge targets. Those connect
application components and remain visible in the environment composition.

`modules/observability` owns the Phase 6 dashboard, alarm topic and policy, native service alarms,
structured-log filters, and Outbox EMF alarms. It accepts resource names rather than entire service
objects, preventing an observability module from owning application infrastructure.

VPC, endpoints, RDS, Lambda functions, IAM roles, SNS, and EventBridge remain in the `dev` root. The
database secret and endpoint policies depend on application identities and destinations; one broad
"platform" module would conceal those relationships and create a tightly coupled input surface.

## IAM and resource-policy changes

| Boundary | Restriction |
|---|---|
| SNS/EventBridge to SQS | Service principal + exact source ARN + source account |
| CloudWatch to alarm SNS | CloudWatch service + source account |
| Secrets Manager endpoint | Only the five database-using Lambda role ARNs, one secret ARN |
| EventBridge endpoint | Only Payment Outbox role, one event bus |
| SNS endpoint | Only Order Outbox role, one topic |
| API Gateway/EventBridge Lambda invoke | Source ARN + source account |
| Lambda logs | Each role writes only its own log group |
| Consumers | Each role receives/deletes only its declared source queue(s) |

The remaining IAM `Resource = "*"` statements are only Lambda VPC ENI lifecycle actions such as
`ec2:CreateNetworkInterface` and `ec2:DescribeSubnets`. AWS does not expose practical resource-level
scoping for all required actions. Network security groups and exact endpoint policies provide the
additional boundary.

IAM cannot replace PostgreSQL authorization. The current educational design still uses the
RDS-managed master credential and one instance for Payment and the Order schema. Production should
use migration automation and separate least-privilege database roles.

## Environment and safety controls

Reviewed dev values live under `infrastructure/terraform/environments/dev`. Real `.tfvars` files are
ignored. `expected_aws_account_id` should be set before planning; a root check rejects credentials for
another account.

When `environment = "prod"`, Terraform rejects the configuration unless RDS has:

- deletion protection;
- a final snapshot on destroy;
- Multi-AZ enabled;
- at least seven days of automated backups.

The `prod` directory intentionally contains guidance instead of fake production defaults. Production
also requires deliberate account, networking, KMS, capacity, incident, and CI/CD decisions.

API Gateway now writes structured access logs, enables detailed route metrics, and applies configurable
rate and burst limits. All application/API log retention uses one environment variable.

## State and module refactoring

The default remains local state for inexpensive learning. `backend.tf.example` demonstrates an S3
backend with encryption, a unique environment key, and native lock files. The state bucket must be
bootstrapped separately so this root does not try to manage its own backend.

If Phase 6 was already applied, do not run ad-hoc `terraform state mv`. The checked-in `moved.tf`
declarations map the four queue flows and observability resources into their module addresses. Run:

```powershell
terraform init
terraform plan -var-file=..\environments\dev\terraform.tfvars
```

Review that the plan reports moves rather than queue replacement. Stop if a queue, DLQ, or database
is marked for replacement. Back up remote state before changing backend or module addresses.

For a new environment, the same declarations are harmless because the old addresses do not exist.

## Verification

```powershell
.\mvnw.cmd clean verify

.\.tools\terraform-1.15.8\terraform.exe fmt -check -recursive infrastructure\terraform
.\.tools\terraform-1.15.8\terraform.exe -chdir=infrastructure\terraform\dev init -backend=false
.\.tools\terraform-1.15.8\terraform.exe -chdir=infrastructure\terraform\dev validate
.\.tools\terraform-1.15.8\terraform.exe -chdir=infrastructure\terraform\modules\sqs-redrive-flow init -backend=false
.\.tools\terraform-1.15.8\terraform.exe -chdir=infrastructure\terraform\modules\sqs-redrive-flow test
.\.tools\terraform-1.15.8\terraform.exe -chdir=infrastructure\terraform\modules\observability init -backend=false
.\.tools\terraform-1.15.8\terraform.exe -chdir=infrastructure\terraform\modules\observability test
```

The module tests use mocked AWS providers. They validate module planning and stable naming contracts
without AWS credentials, network calls during the test itself, or resource creation.

## Trade-offs

- Modules reduce duplication but introduce state addresses and input/output contracts.
- `moved` blocks make this refactor safe only when the existing resources match the documented Phase
  6 addresses; every real plan still requires review.
- One root per environment is simpler for learning but has a larger blast radius than separate
  networking, data, and application states.
- AWS-managed encryption is retained. Customer-managed KMS keys would require key lifecycle and key
  policies that are intentionally not added decoratively.
- API throttling protects cost/downstream load but is not authentication or authorization.
- Remote state improves collaboration but creates a separately secured bootstrap dependency.
