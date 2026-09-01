# Bash local scripts

These scripts are Bash equivalents of the PowerShell scripts in `scripts/local`. They are kept in a
separate directory so both interfaces can coexist without changing the tested PowerShell workflow.

They are intended for Ubuntu on WSL2. Every simulated AWS command runs through `awslocal` inside the
LocalStack container. Terraform is restricted to `infrastructure/terraform/local`, whose resources
use LocalStack and fake account `000000000000`; these scripts do not deploy to a real AWS account.

## Prerequisites

- WSL2 with Ubuntu and Docker Desktop WSL integration;
- Bash 4 or newer;
- `jq`, `curl`, Git, Java 17, and a Linux Terraform CLI (version 1.9 or newer);
- a LocalStack Hobby token in `.env`, as described in the main local-development guide.

Run the scripts from the repository root in WSL2:

```bash
bash ./scripts/bash/local/build.sh
bash ./scripts/bash/local/start.sh
bash ./scripts/bash/local/provision.sh
bash ./scripts/bash/local/happy-path.sh
```

The remaining individual tests are:

```bash
bash ./scripts/bash/local/smoke-test.sh
bash ./scripts/bash/local/dlq-test.sh
bash ./scripts/bash/local/failure-path.sh
bash ./scripts/bash/local/outbox-recovery-test.sh
bash ./scripts/bash/local/consumer-dlq-test.sh
bash ./scripts/bash/local/saga-demo.sh
```

Run the resilience group with:

```bash
bash ./scripts/bash/local/resilience-suite.sh
```

Use `bash ./scripts/bash/local/build.sh --skip-tests` only when intentionally skipping the Maven test
suite. The `.ps1` files remain the reference implementation until both script sets have passed the
same scenarios on the same local environment.
