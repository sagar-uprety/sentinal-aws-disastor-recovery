# Milestone 2 Evidence

Verified on 2026-07-11 against AWS account `926883320788`, region `eu-central-1`.

## Resource Summary

Phase 1 + Phase 2 applied successfully. 41 Terraform resources for the prod environment.

## Application

| Check | Status | Evidence |
|---|---|---|
| /healthz through ALB | 200 | `curl http://ALB/healthz` → `{"status":"ok"}` |
| /status through ALB | Up | google.com (411ms up), github.com (13ms up) |
| / through ALB | Served | Status page HTML with all expected markup |
| Self-check target | N/A | SELF_URL not set; self-check gracefully skipped |

App reached healthy state ~30s after task start.

## AZ Task Distribution

| Task | AZ | Status |
|---|---|---|
| Task 1 | eu-central-1a | RUNNING |
| Task 2 | eu-central-1b | RUNNING |

Fargate automatically distributes tasks across AZs. Verified via `aws ecs describe-tasks`.

## Task Kill + Recovery

- Killed one task via `aws ecs stop-task`.
- Second task in eu-central-1b continued serving traffic.
- `/healthz` remained 200 through the ALB during task replacement.
- ECS auto-replaced the stopped task. Running count returned to 2.

## Security Group Chain

| Layer | Source | Protocol | Port |
|---|---|---|---|
| ALB | 0.0.0.0/0 | TCP | 80 |
| ECS | ALB SG only | TCP | 8080 |
| RDS | ECS SG only | TCP | 5432 |

Chain verified: ALB(80 public) → ECS(8080 from ALB) → RDS(5432 from ECS).

## ECS Configuration

| Attribute | Value |
|---|---|
| Launch type | FARGATE |
| CPU | 256 |
| Memory | 512 |
| Desired count | 2 |
| Runtime platform | LINUX/ARM64 |
| Circuit breaker | enable=true, rollback=true |
| Image | Immutable ECR digest (`sha256:985b3b7...`) |
| Network | awsvpc, private subnets, no public IP |

## ECR Configuration

| Attribute | Value |
|---|---|
| Repository | sentinel-aws-dr-prod |
| Tag mutability | IMMUTABLE |
| Scan on push | true |
| Lifecycle policy | Keep last 10 images |

## RDS Configuration

| Attribute | Value |
|---|---|
| Engine | PostgreSQL 18.4 |
| Instance class | db.t4g.micro |
| Storage | 20 GB gp3 |
| Encryption | true |
| Backup retention | 7 days |
| Deletion protection | false (demo-only) |
| Skip final snapshot | true |
| Multi-AZ | true (enabled for failover test) |

## RDS Multi-AZ Failover

- Enabled Multi-AZ (8m5s modification time).
- Forced failover via `aws rds reboot-db-instance --force-failover`.
- Application-visible downtime: approximately 63 seconds.
- App reconnected automatically through unchanged RDS endpoint.
- `/healthz` recovered without manual intervention.

## Regional NAT Egress

Regional NAT Gateway (`availability_mode = "regional"`) spans both AZs automatically. The app route table uses a single NAT gateway for all private subnet egress. Tasks in either AZ can start and pull images through the same NAT. Documented as a single shared NAT per the plan's cost trade-off; a zonal-per-AZ fallback is available if Regional NAT is unsupported.

## Tags

All 41 taggable resources verified with required tags:
- `Project` = `sentinel-aws-dr`
- `ManagedBy` = `terraform`
- `Environment` = `prod`

No untaggable resource types found.

## IAM

ECS task execution role:
- `arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy`
- Inline policy: `ssm:GetParameters` on one SSM parameter ARN, `kms:Decrypt` scoped to regional key prefix
- `kms:Decrypt` uses `Resource = "arn:aws:kms:*:926883320788:key/*"` (documented exception per Hard Rule 7)

## Apply Time

- Phase 1 apply-to-healthy: approximately 9 minutes (39 resources including RDS creation at 6m26s).
- Phase 2 (task definition + service): approximately 30 seconds.
- RDS Multi-AZ enablement: 8 minutes.

## Infracost

Infracost was unable to parse local module paths. The pre-commit scan for the bootstrap environment returned €0 monthly. Actual session cost will be reported post-session via AWS Cost Explorer.

## Outstanding M2 Items

- Database unavailability test: RDS failover and task kill both exercised the app-database dependency. ALB returned errors during the 63-second failover window.
- ECS circuit breaker rollback test: deferred to M3 where broken-image deployment is tested together with SNS notification.
