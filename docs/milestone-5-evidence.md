# Milestone 5 Evidence

Milestone 5 is repository-only preparation. It intentionally does not apply Terraform, create AWS workload resources, execute a live drill, or claim M6 acceptance.

## Local Validation (2026-07-20)

All commands below completed successfully without AWS credentials or a Terraform apply:

- `terraform fmt -check -recursive terraform`
- `terraform init -backend=false -input=false` and `terraform validate` for bootstrap, prod, and DR, each with a temporary `TF_DATA_DIR` to prevent prior backend metadata from accessing remote state.
- `tflint --recursive --config="$(pwd)/.tflint.hcl" --chdir=terraform`
- `go test -race ./...` from `app`, with a temporary local `postgres:18-alpine` container at the test suite's documented connection URL
- `bash -n scripts/failover.sh scripts/failback.sh scripts/measure.sh scripts/simulate-disaster.sh`
- `pre-commit run actionlint --all-files`
- `pre-commit run checkov --all-files`
- `pre-commit run --all-files`, including Terraform docs, Go lint/vet/race/vulnerability checks, actionlint, Checkov, and Infracost scan.

`infracost breakdown --path terraform --currency EUR` completed through the installed CLI's compatibility scan. It reported a static projected total of EUR 181/month across bootstrap, prod, and DR. This is not AWS Cost Explorer data and must not be reported as actual spend.

## Post-Review Script Hardening (2026-07-20)

A later code and AWS-documentation review found that the M5 scripts did not safely enforce every M6 evidence boundary. The current revisions add explicit outage, promotion, and traffic-switch confirmations; isolate events after the latest `drill_started` marker; require two DR tasks across two AZs and two healthy targets; atomically switch both ARC controls through regional data-plane endpoints; verify authoritative DNS and `/topology`; compute row-based RPO; and verify failback reset phases.

`bash -n scripts/*.sh` and ShellCheck through the official `koalaman/shellcheck:stable` Docker image pass after this hardening. No AWS resources were created and none of the hardened runtime paths have been executed live; M6 remains the acceptance gate.

## Runtime Topology View

The status page now requests `GET /topology` alongside check status. In ECS, it reports the task currently serving the response from ECS metadata v4 plus live service desired/running counts, task IDs, and Availability Zone spread from the ECS control plane. It also caches RDS topology (writer AZ, managed standby AZ, replica source, and instance status) for 30 seconds. The task role grants read-only ECS topology calls and `rds:DescribeDBInstances`; local development returns unavailable AWS topology instead of requiring credentials.

Focused Go unit checks, `go vet`, Terraform validation, Checkov, actionlint, shell syntax, and PostgreSQL-backed Go tests passed after this addition. M6 validates the view against live ECS/RDS topology.

## Terraform Workflow

`.github/workflows/terraform.yml` provides:

- Pull request quality checks: Terraform format, root-module validation without remote state, TFLint, and Checkov.
- Same-repository pull request plan and Infracost-diff comments. Fork pull requests do not receive AWS credentials or execute Terraform plans.
- Manual `plan`, `deploy`, and guarded `destroy` operations. Deploy uses prod-foundation, image-push, prod-service, then DR order. Destroy uses DR, then prod order.
- `terraform-production` environment gating for any operation that reads remote state or changes AWS.

Before its first GitHub Actions run, repository settings must provide:

- Environment `terraform-production` with required reviewers.
- Bootstrap apply output `terraform_github_actions_role_arn`, set as repository variable `AWS_TERRAFORM_ROLE_ARN`. Bootstrap manages this reviewed, explicit-action Terraform role; the existing `AWS_ROLE_ARN` is app-deploy-only and must not be reused.
- Repository secret `INFRACOST_API_KEY` for pull-request cost comments.

These are M6 live-environment prerequisites. The role is declared in bootstrap configuration but is not created until the approved bootstrap apply.

## Final Session Procedure

1. Apply bootstrap, set `terraform_github_actions_role_arn` as `AWS_TERRAFORM_ROLE_ARN`, then approve the `terraform-production` environment.
2. Dispatch `terraform.yml` with `action=deploy` to build prod, publish and replicate the immutable image, create prod service, and build DR pilot light.
3. Verify prod, DR, replication, ECR image digest, SSM metadata, and ARC initial state before beginning a drill.
4. Run first drill. Complete and measure topology reset before second drill.
5. Run second drill. Capture terminal, CloudWatch/SNS, status-page, database, DNS, and Cost Explorer evidence.
6. Dispatch `terraform.yml` with `action=destroy` and `confirm_destroy=DESTROY` after evidence collection, unless current RDS topology requires a different dependency-safe destroy order.

## Pending Live Evidence

- GitHub Actions PR plan and Infracost comments.
- Approval-gated deployment and destroy workflow runs.
- Second drill RTO/RPO and topology-reset duration.
- DR outage-window query/export, recording, final Cost Explorer amount, and teardown output.
- ECS task/AZ and RDS writer/standby topology panel observed during the final HA and pilot-light drills.
