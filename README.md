# Sentinel - Resilient Status Page on AWS

A multi-AZ AWS workload with pilot light DR in a second region, fully defined in Terraform. The app monitors external sites and confirms public reachability after recovery, while AWS-native health signals and drill timestamps measure the outage, RTO, and RPO.

Portfolio project by Sagar Koirala. Target: Senior DevOps Engineer / Platform Engineer (Germany).

## Status

Work in progress.

- Milestones 0-3 are complete.
- Milestone 4 has one real failover rehearsal, PITR restore, and DR implementation evidence. Workload resources were then destroyed to control cost.
- Milestone 5 repository work is locally validated but remains uncommitted. A post-review script hardening pass is syntax-checked and awaits live M6 execution.
- Milestone 6 performs final deployment, two measured drills, recording, cost review, and teardown in one dedicated live-environment session.

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

Do not run live deployment or recovery commands until Milestone 6. Before that session, configure GitHub environment `terraform-production`, `AWS_TERRAFORM_ROLE_ARN`, and `INFRACOST_API_KEY` as described in [docs/milestone-5-evidence.md](docs/milestone-5-evidence.md).

Use [docs/runbook-failover.md](docs/runbook-failover.md) for recovery steps and [docs/aws-dr-architecture.drawio](docs/aws-dr-architecture.drawio) for the canonical architecture diagram. Deployment and teardown ordering is defined in `plan.md` and automated by `.github/workflows/terraform.yml`.

Use [docs/runbook-ha.md](docs/runbook-ha.md) for controlled in-region task, AZ-capacity, and RDS Multi-AZ drills. These are separate from regional pilot-light recovery.
