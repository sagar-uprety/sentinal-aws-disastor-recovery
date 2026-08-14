# Pilotlight - AWS Multi-Region Disaster Recovery

An AWS resilience project with an isolated monitoring plane that observes a separate database-backed URL shortener through multi-AZ and pilot-light recovery drills.

The monitor dashboard is served at `https://monitor.pilotlight.sagaruprety.com.np`; its machine-readable health endpoint is `/healthz`.

## Status

Milestones 0 through 7 are complete. M0-M6 built and live-drilled the historical self-monitoring architecture; M7 split it into an isolated monitor plane (`monitor.pilotlight.sagaruprety.com.np`, eu-west-1) observing a separate URL shortener (`shortener.pilotlight.sagaruprety.com.np`, prod eu-central-1 / DR pilot-light eu-west-1), then live-drilled the new two-plane architecture end to end on 2026-08-08. Two real bugs found during that drill (a monitor checker connection-reuse issue across DNS cutover, and a `measure.sh` event-name collision) were fixed and redeployed live; see [docs/milestone-7-evidence.md](docs/milestone-7-evidence.md) for the full account. Measured M7 results:

- **RTO:** 666s (11m6s) against a 30-minute target
- **RPO:** 26.0s, real CloudWatch `ReplicaLag` (target 60s)
- **Failback duration:** 851s (14m11s) from write freeze through verified prod traffic
- **HA: ECS task replacement:** 42s
- **HA: AZ capacity recovery:** 55s
- **HA: RDS Multi-AZ failover:** 412s

Every link present on primary before the outage was verified present in DR after promotion, and a DR-created link was verified present on prod after failback.

Historical M0-M6 results (self-monitoring architecture, superseded by the M7 split) remain retained as evidence in `docs/milestone-6-evidence.md`, `docs/postmortem.md`, and `docs/evidence/m6/`, and are not conflated with the M7 numbers above.

Workload, DR, and monitoring infrastructure are ephemeral by design (see Hard Rule 4 in [plan.md](plan.md)) and are currently destroyed after the M7 drill; only `bootstrap` (state backend, OIDC roles, delegated Route53 zone) is live. The two-plane isolation described below is proven both structurally (DR's Terraform data sources reference only prod, never monitoring; monitoring's Terraform config has no workload data sources at all) and by empty-state `terraform plan`/`terraform plan -destroy` runs on 2026-08-14 confirming zero cross-plane resources in any state file. See [plan.md](plan.md) for milestones and [docs/milestone-7-evidence.md](docs/milestone-7-evidence.md) for full M7 evidence.

## Two-Plane Architecture

Deployed and live-drilled 2026-08-08 (currently torn down between drills, per the ephemeral-infrastructure design above):

- An isolated monitor in eu-west-1 with separate Terraform state, VPC, ECS service, ALB, ECR repository, and on-demand DynamoDB table.
- A monitor task that checks `https://shortener.pilotlight.sagaruprety.com.np/healthz` and reads explicit prod and DR ECS and RDS state through read-only AWS APIs.
- A live drill timeline fed by the same guarded scripts that retain the local evidence log, with events stored in monitor-owned DynamoDB.
- A PostgreSQL-backed URL shortener on the existing eu-central-1 prod and eu-west-1 pilot-light DR environments.
- A Terraform-generated URL creation token passed only through write-only arguments and stored in regional SSM SecureString parameters.
- Failover and failback scripts that use a prod-created link and a DR-created link as application-level data-survival evidence.

## Repository Checks

Run these without deploying infrastructure:

```bash
terraform fmt -check -recursive terraform
tflint --recursive --config="$(pwd)/.tflint.hcl" --chdir=terraform
cd apps/monitor && go test ./...
cd ../url-shortener && go test ./...
bash -n ../../scripts/*.sh
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

Use [docs/runbook-failover.md](docs/runbook-failover.md) for recovery steps. `docs/aws-dr-architecture.drawio` was updated for the two-plane split (isolated monitor drawn as its own box outside both region groups, dashed read-only polling edges into prod/DR, current Pilotlight DNS naming); see `docs/aws-dr-architecture.drawio.png` for an exported, still-editable copy. Deployment and teardown ordering is defined in `plan.md` and automated by `.github/workflows/terraform.yml`.

### Cost

The NAT gateway, ALB, ECS Fargate, RDS Multi-AZ, and SSM Parameter Store are the paid services this project deliberately uses; see plan.md section 4.4 for why each one is necessary and what would break without it. Optional VPC interface endpoints (ECR API/DKR, CloudWatch Logs, SSM) stay disabled by default because their fixed hourly cost is likely greater than the NAT processing they'd save at this traffic level. Actual per-session AWS cost is measured from Cost Explorer after a session, not estimated in advance; a final reported figure is Milestone 8 scope and is not yet recorded. Local `infracost scan` runs as a required pre-commit check before every deploy.

### Least-privilege IAM

- **Bootstrap's** Terraform role deliberately starts from `PowerUserAccess` (see above) pending a CloudTrail-derived least-privilege policy, tracked outside M7/M8.
- **The monitor's** ECS task role holds only read-only `Describe*`/`List*`/`Get*` actions against ECS/RDS (wildcard resources only where those APIs require it, documented in `terraform/modules/monitor-service/main.tf`), plus scoped `dynamodb:PutItem`/`Query` on its own table ARN. It has no ECS, RDS, ARC, Route53, or Terraform mutation permissions.
- **The workload's** ECS task execution role is scoped to the one SSM parameter ARN it needs (regional database password / operator token); it has no visibility into the monitor's DynamoDB table or IAM role.

Normal Terraform deployment and teardown run through manually dispatched `.github/workflows/terraform.yml`; pushes run validation only so monitor and workload migrations cannot race their infrastructure foundations. Monitor and workload releases are also manual dispatches after their initial foundations exist. Both failback topology-reset stages run through the separately protected `.github/workflows/recovery.yml`. Time-sensitive promotion, traffic switching, and verification remain local scripts and assume the active AWS CLI credentials already have the required permissions; no separate local recovery role is provisioned.

For a deployment from empty monitor and workload state after bootstrap:

1. Confirm ARC is not provisioned (`create_arc = false`), then dispatch `terraform.yml` with `operation=monitor-foundation`. Monitoring claims the existing apex DNS record; the later DR apply deliberately forgets its historical apex state entry without deleting that record.
2. Set `AWS_MONITOR_ROLE_ARN` from monitoring `github_actions_role_arn` output, then dispatch `monitor.yml` with `mode=publish-only`.
3. Copy monitor `sha256:...` digest and dispatch `terraform.yml` with `operation=monitor-deploy` and that `image_digest`.
4. Dispatch `terraform.yml` with `operation=foundation`. This creates workload prod foundations and ECR without prod ECS service.
5. Set `AWS_ROLE_ARN` from prod `github_actions_role_arn` output, then dispatch `workload.yml` with `mode=publish-only`.
6. Copy workload `sha256:...` digest and dispatch `terraform.yml` with `operation=deploy` and that `image_digest`. Terraform creates prod workload service, then DR pilot light from replicated image.
7. Use `monitor.yml` and `workload.yml` independently for later releases.

**Historical note:** the one-time M7 migration from the retained M6 workload used a variant of this sequence, omitting workload `foundation` and reusing the existing prod ECR repository, since prod already existed from M6. That path no longer applies now that workload/monitoring state is empty; use steps 1-7 above for any future deploy.

Before the first monitoring foundation, bootstrap IAM needs one reviewed update because the existing Terraform OIDC role cannot grant itself access to new monitoring role names. Run `scripts/bootstrap.sh plan`, review the saved plan, then request explicit approval before `CONFIRM_BOOTSTRAP=APPLY_BOOTSTRAP scripts/bootstrap.sh apply`. Do not apply bootstrap changes through an unreviewed direct command.

Use [docs/runbook-ha.md](docs/runbook-ha.md) for controlled in-region task, AZ-capacity, and RDS Multi-AZ drills. These are separate from regional pilot-light recovery.
