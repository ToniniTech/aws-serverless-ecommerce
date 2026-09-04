# Bash local scripts

These are the reference scripts for local development and the LocalStack E2E pipeline. Equivalent
PowerShell scripts remain available in `scripts/local` for Windows users.

They are intended for Linux, GitHub Actions, Git Bash on Windows, or Ubuntu on WSL2. Every simulated
AWS command runs through `awslocal` inside the LocalStack container. Terraform is restricted to
`infrastructure/terraform/local`, whose resources use LocalStack and fake account `000000000000`;
these scripts do not deploy to a real AWS account.

## Prerequisites

- Linux with Docker, Git Bash with Docker Desktop, or WSL2 with Docker Desktop integration;
- Bash 4 or newer;
- `jq`, `curl`, Git, Java 17, and a Linux Terraform CLI (version 1.9 or newer);
- a LocalStack Hobby token in `.env`, as described in the main local-development guide.

Run the scripts from the repository root:

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
suite. The GitHub Actions workflow `.github/workflows/localstack-e2e.yml` initially runs only the
happy path; add `resilience-suite.sh` after that workflow is stable.
