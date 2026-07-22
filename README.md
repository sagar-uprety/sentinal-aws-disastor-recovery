# Sentinel - Resilient Status Page on AWS

A multi-AZ AWS workload with pilot light DR in a second region, fully defined in Terraform. The app monitors external sites and confirms public reachability after recovery, while AWS-native health signals and drill timestamps measure the outage, RTO, and RPO.

The dashboard is served at `https://sentinel.sagaruprety.com.np`; its machine-readable health endpoint is `/healthz`.

Portfolio project by Sagar Koirala. Target: Senior DevOps Engineer / Platform Engineer (Germany).

## Status

Milestones 0 through 6 are complete. Key measured results from the final live drill on 2026-07-22:

- **RTO:** 538s (8m58s) against a 30-minute target
- **RPO:** 0s row-based observation with 12s pre-promotion `ReplicaLag`
- **Failback duration:** 840s (14m) from write freeze through verified prod traffic
- **ECS task replacement:** 61s
- **AZ capacity recovery:** 69s
- **RDS Multi-AZ failover:** 432s

All evidence retained in `docs/milestone-6-evidence.md`, `docs/postmortem.md`, and `docs/evidence/m6/`. Milestone 7 (optional cleanup, cost reporting, destroy) is deferred.

See [plan.md](plan.md) for milestones and [docs/milestone-5-evidence.md](docs/milestone-5-evidence.md) for final-session prerequisites.

## Repository Checks

Run these without deploying infrastructure:

```bash
terraform fmt -check -recursive terraform
tflint --recursive --config="$(pwd)/.tflint.hcl" --chdir=terraform
cd app && go test ./...
bash -n ../scripts/*.sh
pre-commit run --all-files
```

`terraform validate` needs an initialized module directory but does not need remote state. Use a temporary Terraform data directory so prior local backend metadata cannot request AWS credentials:

```bash
for root in terraform/environments/bootstrap terraform/environments/prod terraform/environments/dr; do
  data_dir="$(mktemp -d)"
  TF_DATA_DIR="$data_dir" terraform -chdir="$root" init -backend=false -input=false
  TF_DATA_DIR="$data_dir" terraform -chdir="$root" validate
done
```

## Final Live Session

Do not run live deployment or recovery commands until Milestone 6. Before that session, configure protected GitHub environments `terraform-production` and `production`, repository variables `AWS_TERRAFORM_ROLE_ARN` and `AWS_ROLE_ARN`, and secret `INFRACOST_API_KEY` as described in [docs/milestone-5-evidence.md](docs/milestone-5-evidence.md).

Bootstrap persists the Terraform state backend, GitHub OIDC roles, and delegated Route53 zone so nameservers remain stable while workload environments are repeatedly created and destroyed. Its Terraform role deliberately starts with AWS `PowerUserAccess` plus exact workload IAM role management, exact `iam:PassRole` targets, and protected-environment OIDC trust. After the full M6 deploy/destroy exercise, CloudTrail-backed IAM Access Analyzer output must be reviewed and tested before replacing `PowerUserAccess` with the observed least-privilege service policy.

Use [docs/runbook-failover.md](docs/runbook-failover.md) for recovery steps and [docs/aws-dr-architecture.drawio](docs/aws-dr-architecture.drawio) for the canonical architecture diagram. Deployment and teardown ordering is defined in `plan.md` and automated by `.github/workflows/terraform.yml`.

Normal Terraform deployment and teardown run through `.github/workflows/terraform.yml`; both failback topology-reset stages run through the separately protected `.github/workflows/recovery.yml`. Time-sensitive promotion, traffic switching, and verification remain local scripts and assume the active AWS CLI credentials already have the required permissions; no separate local recovery role is provisioned.

For a deployment from empty workload accounts after bootstrap:

1. Dispatch `terraform.yml` with `operation=foundation`. This creates prod infrastructure, ECR, and the application OIDC role without an ECS task definition or service.
2. Set `AWS_ROLE_ARN` from the prod `github_actions_role_arn` output, then dispatch `app.yml` with `mode=publish-only`.
3. Copy the reported `sha256:...` digest and dispatch `terraform.yml` with `operation=deploy` and that `image_digest`. Terraform creates the prod service and DR pilot light from the replicated image.
4. Use normal `app.yml` deployments afterward; each release promotes one immutable digest to prod and DR.

Use [docs/runbook-ha.md](docs/runbook-ha.md) for controlled in-region task, AZ-capacity, and RDS Multi-AZ drills. These are separate from regional pilot-light recovery.
