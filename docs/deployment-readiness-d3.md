# Deployment Readiness D3: Build and Terraform Plan Review

> **Historical readiness snapshot.** This document records one point-in-time D3 build and plan review.
> The ignored plan was never applied or committed and must not be treated as current. Source and build
> outputs have changed since this snapshot; any future deployment requires a newly generated and
> reviewed plan. See the [main README](../README.md) for current deployment status.

## Outcome

D3 successfully rebuilt and tested the application at that checkpoint, authenticated Terraform against the intended
development account, and saved an execution plan. It did not apply the plan or create, update, or
delete AWS resources.

The saved local plan was stored at:

```text
infrastructure/terraform/dev/deployment-d3.tfplan
```

`*.tfplan` and `*.tfvars` are ignored by Git. The plan contains account-specific values and artifact
hashes and must not be committed or reused after source, variables, credentials, provider versions,
or Lambda artifacts change.

## Build verification recorded at D3

```text
Java tests: 41 passed, 0 failed, 0 skipped
```

PostgreSQL integration tests ran against real PostgreSQL 16 Testcontainers. Maven produced these
shaded deployment artifacts:

| Artifact | Size |
|---|---:|
| `payment-order-created-lambda.jar` | 22,118,165 bytes |
| `order-payment-result-lambda.jar` | 21,528,805 bytes |
| `notification-demo-lambda.jar` | 3,617,657 bytes |

The build warnings concern duplicate metadata/resources in shaded dependency JARs. Tests and JAR
creation succeeded; there were no compilation or test failures.

## Tool and environment verification recorded at D3

- Terraform 1.15.8 initialized with the locked AWS provider 6.61.0.
- AWS CLI 2.36.25 was found outside `PATH` and used for read-only identity/availability checks.
- Region: `sa-east-1`.
- The configured account matched the explicit `expected_aws_account_id` guardrail.
- No existing resources with the project/environment tags were found.
- PostgreSQL `db.t4g.micro` offerings are available in the selected Region.
- No credential or private-key pattern was found in repository source/configuration.

The local `deployment.auto.tfvars` contains only the expected account ID and is ignored by Git. It is
not a credential.

## Historical plan summary

```text
Plan: 146 to add, 0 to change, 0 to destroy
```

Important planned resources:

| Category | Count | Notes |
|---|---:|---|
| Lambda functions | 7 | Command, query, consumers, and two Outbox publishers |
| SQS queues | 8 | Four source queues and four independent DLQs |
| SNS topics | 2 | Order fan-out and operational alarms |
| EventBridge bus | 1 | Custom Payment result bus |
| EventBridge rules | 4 | Two result routes and two Outbox schedules |
| EventBridge targets | 6 | SQS and scheduled Lambda targets |
| API Gateway routes | 2 | `POST /orders` and `GET /orders/{orderId}`, both `AWS_IAM` |
| RDS instances | 1 | PostgreSQL 16, `db.t4g.micro`, 20 GiB gp3, Single-AZ |
| Interface VPC endpoints | 3 | Secrets Manager, SNS, and EventBridge across two subnets |
| CloudWatch log groups | 8 | Retention controlled by Terraform |
| CloudWatch metric alarms | 36 | Queue, DLQ, Lambda, API, EventBridge, Outbox, and RDS signals |
| IAM roles/policies | 7 / 7 | Separate runtime identities and scoped service actions |

The plan creates an entirely new stack because the current Terraform state contains no managed AWS
resources. A plan cannot guarantee that an untagged external resource with the same deterministic
name does not exist, although the tag query found no existing project stack.

## Database properties reviewed

```text
Engine: PostgreSQL 16
Class: db.t4g.micro
Storage: 20 GiB gp3
Public access: false
Multi-AZ: false
Backup retention: 1 day
Deletion protection: false
Skip final snapshot: true
```

These values are appropriate only for a disposable educational development environment. Destroying
the stack can permanently remove the database because the dev profile skips the final snapshot.

## Cost review

No exact cost is asserted because prices, account benefits, and regional rates can change. The main
idle cost drivers are:

1. RDS instance hours plus provisioned storage and backups. RDS billing continues while the instance
   is available; stopping it removes instance-hour charges but not storage charges.
2. Three interface VPC endpoints in two Availability Zones. AWS charges each provisioned endpoint
   per Availability Zone-hour and for processed data, so this design has six endpoint/AZ billing
   units while active.
3. Thirty-six CloudWatch alarms, five log metric filters, custom EMF metrics, log ingestion, and log
   retention.
4. Lambda, API Gateway, SQS, SNS, EventBridge, and Secrets Manager usage.

Review current official pricing immediately before apply:

- [RDS for PostgreSQL pricing](https://aws.amazon.com/rds/postgresql/pricing/)
- [AWS PrivateLink interface endpoint billing](https://docs.aws.amazon.com/vpc/latest/privatelink/privatelink-access-aws-services.html#privatelink-access-aws-services-pricing)
- [CloudWatch pricing](https://aws.amazon.com/cloudwatch/pricing/)

For a short-lived demo, destroy the stack after testing and confirm that the RDS instance, VPC
endpoints, alarms, logs, and snapshots no longer generate unwanted cost.

## Security blocker before D4

The available `default` profile authenticated as the AWS account root user. It was used only for
read-only discovery and plan calculation. D4 must not run `terraform apply` with this identity.

AWS recommends using the root user only for tasks that specifically require it and using temporary
roles or IAM Identity Center for normal administration. Before D4:

1. configure a non-root administrative role or IAM Identity Center permission set;
2. authenticate a temporary CLI session for that role;
3. run `aws sts get-caller-identity` and confirm it is an assumed-role ARN in the same guarded account;
4. rerun `terraform plan` if the provider identity, artifacts, variables, or configuration changed;
5. log out of the root CLI session when it is no longer required.

References:

- [AWS root user best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html)
- [AWS Terraform provider security best practices](https://docs.aws.amazon.com/prescriptive-guidance/latest/terraform-aws-provider-best-practices/security.html)

## State decision before D4

The root currently uses local Terraform state. This is acceptable only for one operator and a
short-lived learning stack when the local state is protected, backed up, and never committed. It is
not appropriate for team or production operation.

The repository includes `backend.tf.example` for an encrypted S3 backend with native lockfile
support. Bootstrapping and migrating to that backend is a separate infrastructure decision because
the state bucket must exist before this root can use it. If D4 intentionally uses local state, losing
the state file will make safe cleanup and drift management harder.

## How the saved plan was inspected

These commands work only if the ignored local plan still exists. They are historical procedure, not
evidence that the plan is present or valid for the current source:

```powershell
terraform -chdir=infrastructure/terraform/dev show deployment-d3.tfplan
```

Useful summary:

```powershell
terraform -chdir=infrastructure/terraform/dev show -json deployment-d3.tfplan |
  ConvertFrom-Json -Depth 100
```

Do not edit or rebuild an artifact after reviewing the plan. Terraform embeds Lambda file hashes in
the plan, so a changed JAR requires a new plan.

## D4 entry criteria after source changes

D4 can start only after a fresh plan is generated and reviewed, explicit approval is given, and all
of the following are true:

- Terraform is authenticated through a temporary non-root identity;
- the account ID still matches the local guardrail;
- the state strategy is explicitly accepted;
- the fresh plan summary and its billable resources are accepted;
- the fresh saved plan reflects the current source, artifacts, variables, credentials, and providers;
- a cleanup window and cost monitoring approach are understood.

D4 may apply only that newly generated and reviewed saved plan. D5 smoke tests and D6 failure/retry
tests remain separate approval gates.
