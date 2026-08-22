# Pilotlight

A multi-region disaster recovery architecture on AWS, implemented as two independent systems: a PostgreSQL-backed URL-shortener workload that runs active in one region with a pilot-light standby in a second, and a monitoring service that lives in its own region, on its own infrastructure, and keeps reporting status regardless of what the workload is doing.

The split matters because a sentry that shares infrastructure with the thing it watches produces useless signal exactly when you need it most: if the workload region goes down, a co-located sentry goes down with it. Here the sentry has its own VPC, its own Terraform state, and its own AWS account-level failure domain, so it keeps observing and recording through every drill, including a full regional failover of the workload.

Recovery follows the pilot-light pattern: the secondary region's network, database replica, and container image exist and stay current at all times, but application compute stays at zero until an operator promotes the database and starts it. That keeps standby cost low while keeping recovery time in minutes, and every step of promotion, traffic switching, and failback is scripted and operator-gated rather than automatic.

## Architecture

### System Overview

![Pilotlight system overview](docs/aws-secondary-architecture.drawio.png)

The primary region (`eu-central-1`) serves live traffic behind an ALB, with two ECS Fargate tasks across two Availability Zones writing to a Multi-AZ RDS PostgreSQL instance. The secondary region (`eu-west-1`) mirrors the same network and load balancer, pre-provisioned but idle: its ECS service runs zero tasks, and its database is a cross-region read replica kept continuously in sync. Route 53 Application Recovery Controller (ARC) holds the only traffic-routing switch: DNS answers depend solely on ARC's routing-control state, never on ALB health directly, so the system can never auto-route users to a secondary region that isn't actually ready. The monitoring plane sits below both regions with its own ALB, ECS task, and DynamoDB-backed check history, polling the workload's public health endpoint and reading ECS/RDS state through read-only AWS APIs.

### Detailed Infrastructure Topology

![Pilotlight detailed infrastructure topology](docs/aws-secondary-architecture-detailed.drawio.png)

This view expands both regions down to subnet level. Each region's VPC is split into three tiers across two Availability Zones: public subnets for the ALB and NAT Gateway, private application subnets for ECS tasks, and isolated database subnets for RDS with no route to the internet. The primary region's RDS instance runs synchronous Multi-AZ (a standby for availability, not a backup) alongside an asynchronous cross-region read replica and cross-region automated-backup replication with a 7-day point-in-time-recovery window (a corruption-recovery path independent of the replica). Container images are built once, pushed to ECR by immutable digest, and replicated to the secondary region's ECR so both regions run the exact same artifact. Secrets (the database password and the workload's link-creation token) are generated as Terraform ephemeral values and written directly to regional SSM Parameter Store SecureString parameters through write-only provider arguments, so plaintext never touches Terraform state.

### Recovery Mechanics

Two independent, complementary mechanisms protect the database, matching the trade-off described in AWS's own pilot-light guidance:

| Mechanism | Purpose | Recovery time |
|---|---|---|
| Cross-region read replica | Always-on standby data path; promoted to standalone primary on failover | Minutes |
| Cross-region automated backup replication (PITR) | Corruption/deletion recovery, since a replica faithfully copies corrupted data and backups don't | Minutes to an hour, restored into an isolated instance |

Traffic never moves automatically. Recovery is a sequence of operator-gated, scripted steps, each one verifying the previous step actually succeeded before proceeding:

1. **Detect**: confirm the primary is actually down (health checks, not assumption).
2. **Promote**: validate replica freshness, promote it to a standalone writer, scale secondary compute to two tasks across two AZs, verify application-level writes succeed.
3. **Switch**: atomically flip the pre-provisioned ARC routing controls (primary off, secondary on) in a single data-plane call, then verify authoritative DNS and public traffic are actually being served from the new region.
4. **Fail back**: once the original region is healthy again, rebuild it as a fresh replica of the (now-authoritative) secondary database, freeze writes, promote it back, and reverse the ARC switch.

Design targets: **RTO ≤ 30 minutes** end-to-end (detection through verified traffic on secondary), **RPO ≤ 60 seconds** on the replica-promotion path, measured against real CloudWatch `ReplicaLag`, not assumed.

## Resilience Testing

Each row below is a real injected failure with a defined recovery expectation, not a documentation-only claim:

| Layer | Injected failure | Expected recovery |
|---|---|---|
| Application process | Stop one ECS task | ALB removes the target; ECS replaces it; no user-visible outage |
| Application release | Deploy an image that exits immediately | ECS deployment circuit breaker rolls back automatically; alert fires |
| Application dependency | Make the database unavailable | All tasks lose their shared DB connection together; ALB has no healthy targets; recovers when the DB returns |
| External egress | Block outbound NAT traffic | App still serves cached state; external checks go red; documented as a known limitation |
| AZ compute capacity | Stop all tasks in one Availability Zone | Remaining AZ serves traffic; ECS restores desired count across available capacity |
| AZ database failure | Force an RDS Multi-AZ failover | App reconnects through the unchanged RDS endpoint; interruption is measured, not assumed |
| Regional failure | Stop primary compute, promote secondary replica, start secondary compute, switch traffic | Full pilot-light runbook executes against measured RTO/RPO targets |
| Data corruption | Restore the cross-region automated backup into a new isolated instance | Known pre-corruption data verified present; restored instance is separate from the healthy primary |
| Config/artifact drift | Compare image digest, task definition, and SSM parameter state between regions | Recovery prerequisites confirmed to match before a drill is declared ready |
| DNS/control plane | Exercise the ARC routing control and its documented fallback | Traffic changes only after secondary is verified ready; no automatic routing to a zero-capacity region |

Operational runbooks with the exact commands for each drill:

- [`docs/runbook-failover.md`](docs/runbook-failover.md): full regional failover and failback
- [`docs/runbook-ha.md`](docs/runbook-ha.md): in-region task, AZ-capacity, and RDS Multi-AZ drills

## Repository Layout

```
apps/
  sentry/          isolated monitoring service (Go): checks, history, topology, status UI
  url-shortener/     drill workload (Go): link creation and redirect, PostgreSQL-backed
terraform/
  modules/           reusable building blocks: vpc, alb, ecs-url-shortener, ecs-sentry, rds, ecr, alerting, route53-failover, app-deploy-iam
  environments/
    bootstrap/       persistent state backend, GitHub OIDC roles, delegated Route 53 zone
    monitoring/       isolated sentry, own state, own lifecycle
    primary/            primary region workload
    secondary/              pilot-light secondary region workload
scripts/             drills/ (operator-gated drill automation) and ci/ (CI-only helpers)
docs/                architecture diagrams and operational runbooks
.github/workflows/   CI/CD: per-app build/deploy, Terraform plan/apply/destroy, guarded failback operations
```

## Local Development

Requires Docker and Docker Compose.

```bash
docker compose up --build
```

This starts the sentry (`localhost:8080`), the URL shortener (`localhost:8081`), and a local PostgreSQL instance. The sentry uses a static topology fixture locally instead of live AWS calls, since ECS/RDS topology only exists once deployed.

Create a link:

```bash
curl --request POST \
  --header "Authorization: Bearer local-operator-token" \
  --header "Content-Type: application/json" \
  --data '{"slug":"example","destination_url":"https://example.com"}' \
  http://localhost:8081/links
```

Run tests and static checks without deploying anything:

```bash
cd apps/sentry && go test ./...
cd ../url-shortener && go test ./...
terraform fmt -check -recursive terraform
tflint --recursive --config="$(pwd)/.tflint.hcl" --chdir=terraform
pre-commit run --all-files
```

`terraform validate` needs an initialized module directory but not remote state or AWS credentials:

```bash
for root in terraform/environments/bootstrap terraform/environments/monitoring terraform/environments/primary terraform/environments/secondary; do
  data_dir="$(mktemp -d)"
  TF_DATA_DIR="$data_dir" terraform -chdir="$root" init -backend=false -input=false
  TF_DATA_DIR="$data_dir" terraform -chdir="$root" validate
done
```

## Deploying to AWS

### Prerequisites

- An AWS account, Terraform ≥ 1.11 (write-only secret arguments require it), and a domain you can delegate a subdomain from.
- A GitHub repository with two protected environments (`terraform-production`, `production`) and an `INFRACOST_API_KEY` secret for local cost estimation.
- The AWS provider is pinned to the `~> 6.0` line; see `terraform/environments/*/terraform.tf` for exact version constraints.

### Apply order

Regions apply in a fixed order because secondary and monitoring both depend on resources the earlier stages create (ECR images, SSM parameters, resolved database versions):

1. **Bootstrap**: state backend (S3 + native locking), GitHub OIDC roles, and the delegated Route 53 zone. Applied once, stays up permanently.
2. **Monitoring foundation**: VPC, ALB, ECR, DynamoDB table, and the OIDC role the sentry's own CI will assume.: `terraform.yml` `operation=apply target=monitoring deploy_service=false`
3. **Sentry image + deploy**: build and push the sentry image by immutable digest, then deploy the ECS service against that digest.: `ecs-sentry.yml` `mode=publish-only`, then `terraform.yml` `operation=apply target=monitoring deploy_service=true`
4. **Workload foundation**: primary-region VPC, ECR, and supporting infrastructure, without a running ECS service yet (avoids a chicken-and-egg dependency on an image that doesn't exist).: `terraform.yml` `operation=apply target=primary deploy_service=false`
5. **Workload image + deploy**: build and push the shortener image by digest; Terraform then creates the primary ECS service from that digest and replicates the image into the secondary region's ECR.: `ecs-url-shortener.yml` `mode=publish-only`, then `terraform.yml` `operation=apply target=primary deploy_service=true`
6. **secondary pilot light**: Secondary VPC, ALB, ECS service at zero desired count, cross-region read replica, and automated backup replication, composed from the same Terraform modules with different variables.: `terraform.yml` `operation=apply target=secondary`

Each stage is a `terraform init && terraform plan && terraform apply` in its respective `terraform/environments/*` directory, or the equivalent dispatch of `.github/workflows/terraform.yml`, which runs the same plan/apply through GitHub Actions using short-lived OIDC credentials rather than long-lived AWS keys. One dispatch applies one environment, so the ordering above is enforced by the operator rather than by a single combined run.

Image digests never travel as workflow inputs. `ecs-url-shortener.yml` and `ecs-sentry.yml` write the digest they just pushed to an SSM parameter (`/pilotlight/<env>/image-digest`), and Terraform reads that parameter when `deploy_service=true`. A `publish-only` run is therefore what unblocks the first service-creating apply.

Route 53 ARC routing controls are provisioned on demand, only for the duration of a drill, and torn down afterward. They bill per cluster-hour, so keeping them idle year-round adds no value.

### Cost

Every paid service is a deliberate trade-off documented alongside its Terraform module: one Regional NAT Gateway per environment (external egress for image pulls, health checks, and reliable task startup), an ALB (stable endpoint plus HTTPS termination for tasks with dynamic IPs), ECS Fargate (no OS to patch, no idle EC2 capacity), RDS Multi-AZ (only enabled during active drills), and SSM Parameter Store Standard tier (cheaper than Secrets Manager at this secret count). Optional VPC interface endpoints for ECR/CloudWatch/SSM are disabled by default because their fixed hourly cost outweighs the NAT traffic they'd save at this scale. `infracost` runs as a local pre-commit check before every apply, and actual spend should always be verified against AWS Cost Explorer rather than estimated.

### IAM

- The sentry's ECS task role holds only read-only `Describe*`/`List*`/`Get*` actions against ECS and RDS, plus scoped `dynamodb:PutItem`/`Query` on its own table. No mutation permissions on anything, ever.
- The workload's ECS task execution role is scoped to exactly the one SSM parameter ARN and KMS key it needs to start.
- CI authenticates to AWS through GitHub OIDC with short-lived, per-workflow roles. No long-lived AWS access keys are stored anywhere.
- The bootstrap Terraform role currently starts from a broad managed policy pending a CloudTrail-derived least-privilege policy generated via IAM Access Analyzer; this is a known, documented trade-off rather than a final state.

## License

MIT. See [LICENSE](LICENSE).
