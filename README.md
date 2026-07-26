# Sentinel - Resilient Status Page on AWS

An AWS resilience project evolving toward an isolated monitoring plane that observes a separate database-backed URL shortener through multi-AZ and pilot-light recovery drills.

The dashboard is served at `https://sentinel.sagaruprety.com.np`; its machine-readable health endpoint is `/healthz`.

Portfolio project by Sagar Koirala. Target: Senior DevOps Engineer / Platform Engineer (Germany).

## Status

Milestones 0 through 6 are complete for the historical self-monitoring architecture. Milestone 7 repository implementation is in progress and has not been deployed or verified live. Current code defines an isolated monitor at `sentinel.sagaruprety.com.np` in eu-west-1 and a URL shortener at `app.sentinel.sagaruprety.com.np` across the existing prod and DR environments. Key measured historical results from the live drill on 2026-07-22:

- **RTO:** 538s (8m58s) against a 30-minute target
- **RPO:** 0s row-based observation with 12s pre-promotion `ReplicaLag`
- **Failback duration:** 840s (14m) from write freeze through verified prod traffic
- **ECS task replacement:** 61s
- **AZ capacity recovery:** 69s
- **RDS Multi-AZ failover:** 432s

All historical evidence is retained in drill evidence, `docs/postmortem.md`, and `docs/evidence/m6/`. These values do not yet validate the new two-plane architecture. Milestone 8 contains optional cleanup, cost reporting, and destroy work.


## Two-Plane Architecture

Repository code currently defines, but has not deployed:

- An isolated monitor in eu-west-1 with separate Terraform state, VPC, ECS service, ALB, ECR repository, and on-demand DynamoDB table.
- A monitor task that checks `https://app.sentinel.sagaruprety.com.np/healthz` and reads explicit prod and DR ECS and RDS state through read-only AWS APIs.
- A live drill timeline fed by the same guarded scripts that retain the local evidence log, with events stored in monitor-owned DynamoDB.
- A PostgreSQL-backed URL shortener on the existing eu-central-1 prod and eu-west-1 pilot-light DR environments.
- A Terraform-generated URL creation token passed only through write-only arguments and stored in regional SSM SecureString parameters.
- Failover and failback scripts that use a prod-created link and a DR-created link as application-level data-survival evidence.

## Repository Checks

Run these without deploying infrastructure:

```bash
terraform fmt -check -recursive terraform
tflint --recursive --config="$(pwd)/.tflint.hcl" --chdir=terraform
cd app && go test ./...
cd ../workload && go test ./...
bash -n ../scripts/*.sh
pre-commit run --all-files
```

`terraform validate` needs an initialized module directory but does not need remote state. Use a temporary Terraform data directory so prior local backend metadata cannot request AWS credentials:

```bash
for root in terraform/environments/bootstrap terraform/environments/monitoring terraform/environments/prod terraform/environments/dr; do
  data_dir="$(mktemp -d)"
  TF_DATA_DIR="$data_dir" terraform -chdir="$root" init -backend=false -input=false
  TF_DATA_DIR="$data_dir" terraform -chdir="$root" validate
done
```

## Deployment Prerequisites

Configure protected GitHub environments `terraform-production` and `production`, repository variables `AWS_TERRAFORM_ROLE_ARN`, `AWS_ROLE_ARN`, and `AWS_MONITOR_ROLE_ARN`, and secret `INFRACOST_API_KEY`. `AWS_MONITOR_ROLE_ARN` is the monitoring root's `github_actions_role_arn` output after monitor foundation creation.

Bootstrap persists the Terraform state backend, GitHub OIDC roles, and delegated Route53 zone so nameservers remain stable while workload environments are repeatedly created and destroyed. Its Terraform role deliberately starts with AWS `PowerUserAccess` plus exact workload IAM role management, exact `iam:PassRole` targets, and protected-environment OIDC trust. After the full M6 deploy/destroy exercise, CloudTrail-backed IAM Access Analyzer output must be reviewed and tested before replacing `PowerUserAccess` with the observed least-privilege service policy.

Use [docs/runbook-failover.md](docs/runbook-failover.md) for recovery steps. Existing diagram remains historical; its M7 update is deferred by owner instruction and is not complete. Deployment and teardown ordering is automated by `.github/workflows/terraform.yml`.

Normal Terraform deployment and teardown run through manually dispatched `.github/workflows/terraform.yml`; pushes run validation only so monitor and workload migrations cannot race their infrastructure foundations. Monitor and workload releases are also manual dispatches after their initial foundations exist. Both failback topology-reset stages run through the separately protected `.github/workflows/recovery.yml`. Time-sensitive promotion, traffic switching, and verification remain local scripts and assume the active AWS CLI credentials already have the required permissions; no separate local recovery role is provisioned.

For a deployment from empty monitor and workload state after bootstrap:

1. Confirm ARC is not provisioned (`create_arc = false`), then dispatch `terraform.yml` with `operation=monitor-foundation`. Monitoring claims the existing apex DNS record; the later DR apply deliberately forgets its historical apex state entry without deleting that record.
2. Set `AWS_MONITOR_ROLE_ARN` from monitoring `github_actions_role_arn` output, then dispatch `monitor.yml` with `mode=publish-only`.
3. Copy monitor `sha256:...` digest and dispatch `terraform.yml` with `operation=monitor-deploy` and that `image_digest`.
4. Dispatch `terraform.yml` with `operation=foundation`. This creates workload prod foundations and ECR without prod ECS service.
5. Set `AWS_ROLE_ARN` from prod `github_actions_role_arn` output, then dispatch `workload.yml` with `mode=publish-only`.
6. Copy workload `sha256:...` digest and dispatch `terraform.yml` with `operation=deploy` and that `image_digest`. Terraform creates prod workload service, then DR pilot light from replicated image.
7. Use `monitor.yml` and `workload.yml` independently for later releases.

For the one-time M7 migration from the retained M6 workload, omit workload `foundation`: deploy the monitor through steps 1-3, dispatch `workload.yml` with `mode=publish-only` against the existing prod ECR repository, then dispatch Terraform `operation=deploy` with that workload digest. Prod creates the new token and URL-shortener task definition before the dependent DR plan runs. The DR state migration forgets its historical monitor-apex record without deleting the record now owned by monitoring.

Before the first monitoring foundation, bootstrap IAM needs one reviewed update because the existing Terraform OIDC role cannot grant itself access to new monitoring role names. Run `scripts/bootstrap.sh plan`, review the saved plan, then request explicit approval before `CONFIRM_BOOTSTRAP=APPLY_BOOTSTRAP scripts/bootstrap.sh apply`. Do not apply bootstrap changes through an unreviewed direct command.

Use [docs/runbook-ha.md](docs/runbook-ha.md) for controlled in-region task, AZ-capacity, and RDS Multi-AZ drills. These are separate from regional pilot-light recovery.
