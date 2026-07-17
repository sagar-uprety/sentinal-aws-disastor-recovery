# Project Plan: Resilient Status Page on AWS

Portfolio project! Target roles: Senior DevOps Engineer / Platform Engineer.
This document is the single source of truth for AI agents implementing the project. Follow it exactly. Where this document is silent, prefer AWS official documentation and Terraform AWS provider documentation.

---

## 1. Project Summary

A self-monitoring uptime service ("status page") deployed as a production-grade, highly available AWS workload with automated cross-region disaster recovery using the pilot light strategy. Everything is defined in Terraform. The environment is ephemeral by design: apply, demo, record, destroy.

One-line pitch for the README: "A multi-AZ AWS workload with pilot light DR in a second region, fully defined in Terraform. The app monitors uptime of external sites and of itself, so the recorded failover demo shows the system observing its own outage and recovery, with measured RTO and RPO."

Design rationale to state in the README: the app (customer-facing status page) and Grafana (operator view) intentionally consume the same check data for different audiences, mirroring how real organizations run a public status page alongside internal observability. The app is the workload that fails over; Grafana (local, outside the workload) is how the failover is observed.

Reference architecture basis: AWS whitepaper "Disaster Recovery of Workloads on AWS" (pilot light strategy), AWS Well-Architected Reliability Pillar REL13-BP02.

## 2. Hard Rules (apply to every milestone)

1. No fabrication anywhere. README, docs, and any generated text must describe only what was actually built and measured. RTO/RPO numbers are written only after they are measured in a real drill. Placeholders like "RTO: TBD (measure in Milestone 5)" are used until then.
2. This is a personal project. Never frame it as production or employer work in any generated text.
3. No em dashes or en dashes in any generated text, code comments, or docs. Use commas, periods, or parentheses.
4. Cost discipline: infrastructure is ephemeral and the project owner controls when to run `terraform destroy`; teardown is not a milestone acceptance criterion. NAT gateway and interface endpoint usage are minimized. An AWS Budget already exists as an owner-managed account prerequisite and is not created by this project; verify it is active before each apply and review an Infracost estimate. Provisional ceiling for one complete build and drill session: 15 EUR until measured, accounting for two-AZ Regional NAT and a short-lived ARC routing-control cluster. The final README reports the actual AWS Cost Explorer amount and session duration, never an estimate presented as fact.
5. Regions: primary eu-central-1 (Frankfurt), DR eu-west-1 (Ireland).
6. All project infrastructure via Terraform. The existing Cloudflare parent zone predates this project; one documented NS delegation from Cloudflare to a Route53 subdomain is the only external prerequisite and is not presented as project-managed infrastructure. No other console-created resources are allowed except the initial state bootstrap if unavoidable, and even that should be scripted.
7. Least privilege IAM everywhere. Scope resources to specific ARNs whenever the AWS action supports resource-level permissions. Some list, describe, telemetry, and service bootstrap actions require `Resource = "*"`; every such exception must use only the required actions and be documented beside the policy. No wildcard actions such as `Action = "*"` are allowed. CI scans IAM policies with Checkov.
8. Runtime secrets use SSM Parameter Store SecureString. Generate the database password as a Terraform ephemeral value and pass it only to AWS provider write-only arguments (`aws_db_instance.password_wo` and `aws_ssm_parameter.value_wo`), which require Terraform 1.11 or newer. Never use ordinary `password` or `value` arguments for secrets, because they persist plaintext in state. Never place secret values in outputs, code, command arguments, or CI logs. Terraform state may store only parameter ARNs, versions, and metadata.
9. App stays trivial: one container, one main Postgres table, three or four endpoints, no auth, no user accounts, no alert-rule engine. If a change makes the app more interesting than the infrastructure, reject it.
10. Every Terraform module gets a README with inputs, outputs, and one sentence on design intent.
11. All taggable AWS resources carry these tags:

    | Key | Value |
    |---|---|
    | `Project` | `sentinel-aws-dr` |
    | `ManagedBy` | `terraform` |
    | `Environment` | `prod` or `dr` (set per-environment) |
    | `Purpose` | Brief role (e.g. `state-storage`, `container-orchestration`, `database`) |

    Set via `default_tags` in each environment's provider block, not per-resource. Terraform modules propagate them automatically, or accept a `tags` variable that merges with caller-provided tags.
12. Bootstrap resources (state bucket, lock table) use the same tag scheme with `Environment=prod` and `Purpose=state-storage`.

## 3. Application Specification

Language: Go (fallback: Python FastAPI if Go blocks progress). Single Docker container, distroless or alpine base, non-root user.

Behavior:
- Background loop (goroutine with ticker) checks each target URL every 30 seconds with a 5 second timeout via HTTP GET.
- Each check writes one row: target_url, status_code (nullable), response_ms, is_up (bool), checked_at (timestamptz).
- Default targets seeded at startup: https://www.google.com, https://github.com, and the app's own public ALB URL (injected via env var SELF_URL; skip self-check gracefully if unset).

Endpoints:
- `GET /healthz` returns 200 and `{"status":"ok"}` if the DB is reachable. Used by ALB target group health check.
- `GET /targets` returns the target list as JSON.
- `GET /status` returns the latest check per target.
- `GET /history?target={url-encoded target URL}` returns the last 100 checks for that exact target URL (exact match on checks.target_url, no substring or LIKE matching; targets sharing a host suffix must not collide).
- `GET /` serves one static HTML page styled as a clean, modern status page (this page appears in the demo recording, so it must look polished). UI spec, all in a single static file with inline CSS and a small inline script, no framework, no npm, no build step:
  - Overall status banner at the top: "All systems operational" (green) when every target is up, "Service disruption" (red) otherwise, derived from `/status`.
  - One card per target: colored status dot (green/red), target hostname, latest response time in ms, "checked Xs ago", and an uptime percentage for the last 24 hours (computed server-side from the checks table, returned by /status).
  - Per card, a strip of the last 50 checks rendered as thin vertical bars (inline SVG or canvas, approx 30 lines, no charting library): green bar height maps to response time, red bar for a failed check. During the disaster drill recording this strip visibly turns red and recovers, which is the key visual moment.
  - Optional, only if it fits inside the time cap: one response-time line chart per target (last 100 checks) using a single lightweight chart library loaded via one CDN script tag (uPlot preferred, Chart.js acceptable). This is the only permitted external dependency. Still no npm, no build step, still one HTML file.
  - Clean minimal styling: single accent palette, system font stack, generous whitespace, looks reasonable on mobile. Auto-refresh every 15 seconds via the inline script.
  - Explicitly forbidden: React or any framework, Tailwind or any CSS build, npm or any build step, more than the one CDN chart library above, theme toggles, animations beyond the refresh. Rich time-series visualization belongs in Grafana (section 4.6), not in the app.

Schema (migration applied at startup, idempotent):
```sql
CREATE TABLE IF NOT EXISTS targets (id SERIAL PRIMARY KEY, url TEXT UNIQUE NOT NULL);
CREATE TABLE IF NOT EXISTS checks (
  id BIGSERIAL PRIMARY KEY,
  target_url TEXT NOT NULL,
  status_code INT,
  response_ms INT,
  is_up BOOLEAN NOT NULL,
  checked_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_checks_target_time ON checks (target_url, checked_at DESC);
```

Deliberate omission, document in app/README.md: checks.target_url has no foreign key to targets. At this scale, orphan rows are harmless, and denormalizing the URL keeps history readable even if a target is removed. State this as a conscious trade-off.

Configuration via env vars only: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, SELF_URL, CHECK_INTERVAL_SECONDS (default 30), PORT (default 8080). ECS injects DB_PASSWORD from the region-local SSM SecureString and ordinary environment values for non-secret fields; the Go app assembles the connection string without logging it. Local development may continue to accept DATABASE_URL as a mutually exclusive convenience input.

Observability in the app: push OTLP metrics to an OTel Collector over HTTP using the OpenTelemetry SDK with an OTLP exporter. Structured JSON logs to stdout. The /metrics endpoint is removed; all telemetry flows through OTLP push to an internal collector, never exposed publicly. The OTel Collector, Prometheus, and Grafana run as ECS services in the private application subnets. Grafana is accessible through the ALB on a restricted path, or via SSM port-forward for the demo.

## 4. Architecture Specification

Version policy:
- Use Terraform 1.15.5 from `.terraform-version`; every root module declares `required_version = ">= 1.11, < 2.0"` because write-only arguments require Terraform 1.11 or newer.
- Use the latest stable AWS provider major 6 release available when a milestone starts, constrained as `~> 6.0`. Add the latest compatible HashiCorp Random provider when ephemeral password generation is implemented in M2; do not declare it before use because the repository rejects unused providers. Run `terraform init -upgrade`, review provider changelogs and the plan, and commit lock files for every root that uses each provider. "Latest" means intentionally upgraded and locked, not an unbounded provider constraint.
- Pin PostgreSQL major 18 while resolving its latest common regional minor as described below. Major upgrades require a separate reviewed change and test; latest does not mean automatic major-version drift.

### 4.1 Primary region (eu-central-1)
- VPC `10.0.0.0/24` across eu-central-1a and eu-central-1b. Allocate two public `/27` subnets for ALB and public ingress, two private application `/27` subnets for ECS, and two isolated database `/28` subnets for RDS. A `/27` has 27 AWS-usable addresses and a `/28` has 11, enough for two steady ECS tasks, deployment overlap, ALB nodes, Regional NAT attachments, and RDS failover with substantial headroom. Reserve the remaining addresses for growth. The DR VPC uses non-overlapping `10.1.0.0/24`; document the address calculation in the module README.
- ALB in public subnets, HTTP :80 only. `sagaruprety.com.np` remains authoritative in Cloudflare. Delegate the `sentinel.sagaruprety.com.np` subdomain to a Route53 public hosted zone using NS records in Cloudflare. Publish the workload at `status.sentinel.sagaruprety.com.np`; Route53 manages only records below the delegated `sentinel` zone and the operator-gated regional route. Direct ALB testing does not require DNS. HTTPS and ACM remain optional enhancements and must not block recovery work.
- ECS Fargate cluster. One service, desired_count = 2 in demo mode, 1 in idle-testing mode. Tasks in private subnets. CPU 256, memory 512. Fargate does not support placement strategies or constraints; AZ spread across the two private subnets is automatic and best-effort, verified with evidence in M2 rather than configured.
- Pin an explicit supported Fargate Linux platform version in Terraform and record it in the module README; do not rely silently on a changing `LATEST` value.
- Egress for image pull, logs, SSM retrieval, and external checks uses one Regional NAT Gateway configured for both AZs plus the free S3 gateway endpoint. Regional NAT is part of every applied prod and DR environment, not a feature flag, because the workload cannot perform its core checks or reliably start replacement tasks without it. AWS bills one NAT Gateway-hour per supported AZ, so this has roughly the fixed hourly cost of one zonal NAT per AZ, not one zonal NAT total. It avoids the single-NAT AZ dependency and simplifies routing. Confirm Regional NAT availability in Frankfurt and Ireland before implementation; fallback is one zonal NAT per AZ, never one shared zonal NAT.
- RDS PostgreSQL: pin major version 18 and use `data.aws_rds_engine_version` with `version = "18"` and `latest = true` to select the latest minor available in both eu-central-1 and eu-west-1 at apply time. Record the resolved minor in evidence and require both regions to match before replica creation. Enable automatic minor upgrades; never float automatically to a new major. Use db.t4g.micro if orderable for the resolved version in both regions, otherwise select the smallest supported Graviton class and document the cost change. Configure 20 GB gp3, backup_retention_period = 7, storage encryption, deletion_protection = false, and skip_final_snapshot = true. Module README must warn that the deletion settings are demo-only and that burstable instances can lag under sustained load. `multi_az` is true for the Milestone 2 HA test and full demo, false only for explicitly labeled basic testing.
- Multi-AZ RDS synchronously maintains a standby in another AZ for availability; that standby is not a backup. RDS automated backups provide the seven-day regional PITR window and are stored by the managed service independently of one DB AZ. Cross-region automated backup replication separately copies recovery data to eu-west-1 for regional disaster and corruption recovery. No manual or final snapshot is retained after teardown unless a drill explicitly creates one and deletes it after evidence collection.
- Security groups chained: ALB (ingress 80 from 0.0.0.0/0) -> ECS tasks (ingress 8080 from ALB SG only) -> RDS (ingress 5432 from ECS SG only).
- ECR repository with lifecycle policy (keep last 10 images).
- State-safe SSM credentials: Terraform 1.11+ creates one ephemeral random password during the prod apply. The same ephemeral value flows to RDS through `password_wo` and to Standard-tier SecureString parameters in eu-central-1 and eu-west-1 through `value_wo`, using aliased AWS providers. Keep `password_wo_version` and both `value_wo_version` values synchronized through one explicit credential version variable. The plaintext never enters Terraform state. The prod stack owns both regional parameter metadata so the DR parameter exists before failover and the promoted replica uses the inherited password. ECS task execution roles receive narrowly scoped `ssm:GetParameters` and `kms:Decrypt` permissions for only their regional parameter and key.

### 4.2 DR region (eu-west-1), pilot light
- Mirrored VPC `10.1.0.0/24` with the same `/27` public, `/27` application, and `/28` database subnet pattern, two-AZ Regional NAT Gateway, free S3 gateway endpoint, ALB, ECS cluster, task definition, and service with desired_count = 0. Paid interface endpoints remain optional and disabled by default. Terraform composes the same modules with different variables. The recovery environment cannot process requests until the database is promoted and compute is started, so this is pilot light rather than warm standby. Live replicated data and core network resources remain available while application compute is switched off, matching the AWS pilot-light guidance.
- Database, two complementary mechanisms (state the rationale for both in the README):
  1. Cross-region read replica: a single-AZ replica in eu-west-1 using the smallest compatible Graviton class resolved for both regions in M2, created from the primary (streaming replication, RPO of seconds under demo load). On failover it is promoted to standalone primary, which takes minutes. This keeps the data resource always on in the recovery region, matching the whitepaper pilot light definition, and is the fast RTO path. It runs only during demo sessions (the whole environment is ephemeral).
  2. RDS Cross-Region Automated Backup Replication (Terraform resource `aws_db_instance_automated_backups_replication`, snapshots plus transaction logs, point-in-time restore in eu-west-1). Set its `retention_period` to 7 to match the primary's PITR window; destination retention is independent of the source and defaults differently if left unset. This is the corruption protection layer: a replica faithfully replicates corrupted or deleted data, so PITR backups are what allow rewinding to the last good state, per the whitepaper caveat. Cost is cents.
- The DR network and ALB span two AZs. When recovery starts, ECS scales to two tasks distributed across those AZs. The always-on read replica is intentionally single-AZ to control pilot-light cost; immediately after service recovery, convert the promoted DR database to Multi-AZ as a separate stabilization step and measure that duration. State clearly that the recovered service has reduced database availability between promotion and completion of this conversion.
- The failover script uses replica promotion as the primary recovery path; the runbook documents PITR restore as the corruption-scenario alternative, including its expected 15-60 minute restore duration.
- ECR replication rule so the image exists in eu-west-1.

Apply prod before DR because the replica, backup replication, and ECR replication depend on primary resource identifiers. Keep environment state separate and pass only documented non-secret outputs through `terraform_remote_state`. Store state in the bootstrap bucket and document that a primary-region S3 outage can prevent Terraform-driven recovery; the failover runbook must remain executable with AWS CLI using recorded resource identifiers. Destroy DR before prod. Promotion changes replica topology and CLI scaling changes ECS desired count, so the runbook must reconcile configuration and Terraform state after every drill.

### 4.3 Failover automation

Recovery objectives, defined before testing:
- End-to-end regional recovery target RTO: 30 minutes from the first confirmed user-visible primary outage until `status.sentinel.sagaruprety.com.np` serves verified traffic backed by writable DR data. Record detection, declaration, promotion, task startup, health verification, and routing as separate phases. Also report operator-invocation-to-recovery automation duration, but do not substitute it for end-to-end RTO.
- Replica-promotion path target RPO: 60 seconds at demo load, measured from the newest primary check visible in DR after promotion.
- PITR corruption path target RPO: no more than the service-supported restore granularity; measure it during the drill rather than assuming a value.

Automation is operator-initiated and then runs end to end. DNS must never route users to an unready pilot light:
- `scripts/simulate-disaster.sh`: records the start timestamp and sets primary ECS desired_count to 0 to simulate regional application failure. It does not alter traffic routing.
- `scripts/failover.sh`: promotes the eu-west-1 read replica to standalone primary, waits for writability, registers a new DR task definition with the promoted endpoint and validated region-local SSM parameter ARN, scales DR ECS service to 2, verifies target health and application writes, then enables the DR traffic route as the final step.
- Traffic switching uses an operator-gated Route53 Application Recovery Controller routing control connected to the `status.sentinel.sagaruprety.com.np` records. Provision the ARC routing-control cluster only for the drill; its published rate was $2.50 per cluster-hour when this plan was revised, but verify current pricing before apply. Include the charge in session evidence. The project owner controls teardown after recording. Fallback: a deliberate Route53 record update after readiness verification, clearly identified as a less resilient control-plane operation. Automatic primary-health-check DNS failover to an unready DR ALB is forbidden.
- `scripts/failback.sh`: documents and automates safe steps where practical. After DR accepts writes, the old primary cannot simply resume. Rebuild the original region from the DR primary, establish reverse replication, verify consistency, switch traffic only after readiness, and restore the intended replication topology. A destructive snapshot-based alternative must state its data-loss and RTO implications.
- `scripts/measure.sh`: timestamps detection, promotion, task startup, health verification, and traffic switch; prints measured RTO and derives RPO from the newest pre-disaster row present after promotion.
- Every script records changed resources. After the drill, update Terraform configuration to the intended topology and run `terraform plan` to inspect drift before apply or destroy. Never use `terraform apply -refresh-only` as a substitute for declaring the desired post-drill configuration.

Control-plane operations create or change configuration, such as promoting RDS, scaling ECS, modifying Multi-AZ mode, or changing Route53 records. Data-plane operations use resources that already exist to serve traffic or toggle pre-created routing state, such as ALB requests, database queries, DNS answers, and ARC routing controls. Pilot light accepts some control-plane dependency to reduce standby cost, but the final traffic switch uses pre-created ARC data-plane controls after all required control-plane recovery steps succeed.

### 4.4 Cost rationale for paid services

Every project service is chosen intentionally. Here is why each paid service is necessary and what would break without it.

**NAT Gateway:** ECS tasks in private subnets need internet egress to check external URLs and start reliably without paid interface endpoints. Without NAT, the app can still serve stored results but cannot perform its core checks. Putting tasks in public subnets with public IPs broadens exposure and is rejected. One NAT gateway resource (`availability_mode = "regional"`, spanning both AZs per 4.1) is therefore created by default in each applied environment, with no enable/disable variable; it is billed per supported AZ, not at a single zonal rate. Exact regional hourly and data-processing charges come from Infracost and the final bill.

**ALB:** Required for load balancing across ECS tasks, HTTP health checks, and the Route53 target. Fargate tasks have dynamic IPs, so a stable endpoint is needed. A Network Load Balancer does not provide the required Layer 7 health and routing behavior. Use current regional Infracost data instead of hard-coded rates.

**ECS Fargate:** The compute platform for the container. The project's core premise is a containerized AWS workload with HA/DR. Lambda is unsuitable for the long-lived checking loop, while EC2 introduces OS maintenance and idle instance capacity. Use current regional Infracost data instead of hard-coded rates.

**RDS Multi-AZ:** Multi-AZ is enabled only during demo sessions to test within-region database failover. During basic testing, set `multi_az = false` to reduce cost. Do not assume Free Tier eligibility. Confirm instance availability and current regional rates through the AWS provider and Infracost before implementation.

**VPC endpoints:** The S3 gateway endpoint has no hourly charge and reduces NAT traffic, so it is enabled. ECR API/DKR, CloudWatch Logs, and SSM interface endpoints charge per endpoint per AZ plus data processing. For this ephemeral, low-traffic workload they are disabled by default because their fixed hourly cost is likely greater than NAT processing savings. They remain module options to demonstrate the production trade-off between private AWS API paths, NAT/AZ failure behavior, and cost.

**SSM Parameter Store:** Two regional Standard-tier SecureString parameters hold the same RDS password, one for prod ECS and one for DR ECS. Terraform ephemeral values plus AWS provider write-only arguments keep plaintext out of state. Standard parameters fit the small secret count and avoid Secrets Manager. KMS API charges, if any, are included in measured session cost.

### 4.5 Route53
- Keep health checks for detection and evidence, with a deliberate `failure_threshold` that avoids reacting to a single transient failure. Do not attach automatic failover routing that sends users to DR while its desired count is zero. The final measured drill must use an operator-gated Route53 ARC routing control after `failover.sh` verifies the promoted database, healthy DR targets, and successful writes. A scripted Route53 record update remains an emergency fallback only and must be documented as a less resilient control-plane operation, not presented as equivalent evidence.
- The registered parent domain `sagaruprety.com.np` remains on Cloudflare. Terraform creates the `sentinel.sagaruprety.com.np` Route53 public hosted zone. Add its returned NS records to Cloudflare once, then verify delegation with `dig NS sentinel.sagaruprety.com.np`. Route53 owns `status.sentinel.sagaruprety.com.np` and its ARC routing controls without moving the parent domain away from Cloudflare.

### 4.6 Monitoring
- CloudWatch alarms: ALB 5xx count, ALB healthy host count < 1, ECS running task count < desired, RDS CPU > 80, RDS free storage low. All alarms notify one SNS topic with email subscription.
- EventBridge rule on ECS `SERVICE_DEPLOYMENT_FAILED` -> same SNS topic (circuit breaker visibility).
- OTel Collector, Prometheus, and Grafana run as ECS services in the private application subnets. The app pushes OTLP metrics to the collector, Prometheus scrapes the collector, and Grafana queries Prometheus. All internal, no public metrics endpoint. The Grafana dashboard is provisioned and screenshot-ready for the demo recording.
- CloudWatch alarms are regional. Create and verify alarms in both regions and document that Grafana is the cross-region operator view for the demo; do not imply CloudWatch automatically aggregates regional alarms.

### 4.7 ECS deployment safety
- Deployment circuit breaker enabled with rollback = true.
- The pinned AWS provider (`~> 6.0`, see `terraform.tf`) exposes only `enable` and `rollback` in Terraform's `deployment_circuit_breaker` block as of this writing (tracked upstream: hashicorp/terraform-provider-aws#48748, still open). Do not use `local-exec` or out-of-band service mutations to force an unsupported threshold, because that creates unmanaged drift. Use the provider-supported default failure threshold, measure actual rollback duration, and report it honestly. Re-evaluate only after the pinned provider's resource schema natively supports configurable thresholds; check the provider CHANGELOG before assuming.

### 4.8 Resilience test matrix

No finite demo proves every possible failure. Test one representative recovery path at each layer and state untested risks explicitly:

| Layer | Injected failure | Expected recovery and evidence | Milestone | Status |
|---|---|---|---|---|
| Application process | Stop one ECS task | ALB removes target; ECS replaces task; no user-visible outage with second task healthy | M2 | Mandatory |
| Application release | Deploy image that exits | ECS circuit breaker rolls back; SNS notification arrives; measured rollback time | M3 | Mandatory |
| Application dependency | Make database unavailable during a controlled test | Not a partial-HA case: every task shares one RDS instance, so all targets go unhealthy together; ALB has no healthy targets and returns an error; M2 verifies structured logs and recovery, then M3 verifies alarms and SNS without leaking credentials | M2/M3 | Mandatory |
| External egress | Remove the NAT route or otherwise block controlled egress | App still serves stored status; external checks turn red; replacement-task limitation is documented; restore route afterward | M2 | Mandatory |
| Availability Zone compute | Stop all ECS tasks placed in one AZ | Remaining-AZ task serves traffic; ECS restores desired count across available capacity (Fargate spread is automatic and best-effort, not a configurable placement strategy, so this row is verified with evidence, not configured) | M2 | Mandatory |
| Availability Zone database | Force RDS Multi-AZ failover | App reconnects through unchanged RDS endpoint; measure application-visible interruption | M2 | Mandatory |
| Regional application and database | Stop primary ECS, promote DR replica, start DR ECS, then switch traffic | Pilot-light runbook meets measured RTO/RPO targets | M5 | Mandatory |
| Data corruption or deletion | Restore cross-region automated backup to a new isolated DB | Verify a known pre-corruption row exists in the restored, isolated DB without replacing healthy primary; measure restore and validation time; delete the restored instance after evidence capture | M4 | Mandatory |
| Artifact/configuration drift | Verify image digest, task definition, SSM parameter metadata, service quotas, and Terraform plan in DR | Recovery prerequisites match primary before declaring drill readiness | M4 | Mandatory |
| DNS/control plane | Exercise ARC routing control and document fallback | Traffic changes only after DR readiness; no automatic route to zero-capacity DR | M4 | Mandatory |

All ten rows are mandatory; none are documentation-only. Do not simulate an AWS regional outage by claiming that scaling ECS to zero is equivalent. Label it accurately as a controlled regional workload failure used to execute and measure the same recovery path.

## 5. Repository Layout

```
aws-resilient-status-page/
├── app/
│   ├── Dockerfile
│   ├── main.go (or app/ package layout)
│   ├── static/index.html
│   └── README.md
├── terraform/
│   ├── modules/
│   │   ├── vpc/
│   │   ├── alb/
│   │   ├── ecs-service/
│   │   ├── rds/
│   │   ├── monitoring/
│   │   ├── github-oidc/      # OIDC provider + deploy role for GitHub Actions (added in M3)
│   │   ├── route53-failover/
│   │   └── ecr/
│   └── environments/
│       ├── bootstrap/        # state bucket with S3 locking + DynamoDB compatibility table
│       ├── prod/             # eu-central-1
│       └── dr/               # eu-west-1
├── scripts/
│   ├── simulate-disaster.sh
│   ├── failover.sh
│   ├── failback.sh
│   └── measure.sh
├── .github/workflows/
│   ├── app.yml               # build, test, push to ECR, deploy
│   └── terraform.yml         # fmt, validate, tflint, checkov, plan on PR; apply/destroy are separate workflow_dispatch jobs with approval, never on merge
├── docker-compose.yml        # local dev stack: app, postgres, otel collector, Prometheus, Grafana
├── observability/            # local otel/Prometheus/Grafana configs consumed by docker-compose.yml
├── docs/
│   ├── architecture.md       # diagram, state dependencies, lifecycle, and decisions
│   ├── postmortem.md         # written after the first real drill
│   ├── runbook-failover.md
│   └── demo.gif / demo.mp4
└── README.md
```

## 6. Milestones

Each milestone has acceptance criteria. An agent must not mark a milestone complete until every criterion is verifiably met (command output or screenshot). Infrastructure teardown is performed separately by the project owner and does not block milestone completion.

### Milestone 0: Bootstrap and scaffolding (0.5 day)
Tasks:
- [x] Create repo with the layout above, root README stub, .gitignore (Terraform, Go), LICENSE (MIT).
- [x] Upgrade and lock tooling before backend initialization: Terraform 1.15.5, `required_version >= 1.11, < 2.0`, and AWS provider 6.54.0. Run `terraform init -upgrade` and commit regenerated lock files for bootstrap, prod, and DR. Add and lock Random when its first resource is implemented in M2; declaring an unused provider fails the repository's TFLint rules.
- [x] `terraform/environments/bootstrap`: S3 bucket (versioned, encrypted) with native S3 state locking plus a tagged DynamoDB compatibility lock table. Applied in eu-central-1 and kept running (cost: cents).
- [x] Configure S3 backend in prod and dr environments with the account-specific bucket and native S3 lock files.
- [x] Pre-commit hooks: terraform fmt, tflint.
Acceptance criteria:
- [x] `terraform init` succeeds in prod and dr with remote state.
- [x] `terraform providers` and committed lock files show only reviewed current provider versions; no root remains locked to AWS provider 5.x.
- [x] Bootstrap, prod, and DR root modules each declare `required_version = ">= 1.11, < 2.0"`.
- [x] Bootstrap state bucket has versioning, server-side encryption, and public-access blocking enabled; the bucket and lock table expose the Hard Rule 12 tags (`Project`, `ManagedBy`, `Environment=prod`, `Purpose=state-storage`).
- [x] Existing owner-managed AWS Budgets were healthy before the bootstrap apply; evidence retained in `docs/milestone-0-evidence.md` without importing or managing budgets in Terraform.
- [x] `git log` shows conventional, meaningful commits.

### Milestone 1: Application (1.5 days, hard cap; at most half a day of that on the UI)
Tasks:
- [x] Implement the app per section 3, including OTLP metrics push and the static page.
- [x] Unit tests for the check logic (mock HTTP) and one integration test with Postgres via testcontainers or docker-compose.
- [x] Dockerfile: multi-stage build, non-root, final image under 30 MB for Go. _(4.82 MB)_
- [x] docker-compose.yml for local dev (app + postgres).
- [x] Add DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD env var support per section 3 (line 80). ECS injects these individually in M2/M4, so DATABASE_URL-only cannot receive the region-local SSM password. Keep DATABASE_URL as a mutually exclusive local-dev convenience input. Unit test both configuration paths.
Acceptance criteria:
- [x] `docker compose up` locally: /healthz 200, /status shows real check results within 60 seconds, / renders the status page per the UI spec (banner, cards, last-50-checks strips, auto-refresh), OTLP metrics push to the local collector, and Grafana shows the Sentinel dashboard at localhost:3000.
- [x] Visual check: the page looks like a credible modern status page in a screenshot, and a failed target visibly turns its card and strip red within one refresh cycle.
- [x] Tests pass in CI-runnable form (`go test ./...`), including both database configuration paths.
- [x] App remains single-purpose and infrastructure-focused: one container, PostgreSQL persistence, no auth, no accounts, no alert engine, and no frontend build system. Production Go code is 664 physical lines across five small files; this replaces the inaccurate approximate 400-line checkbox while preserving its scope-control intent.
- [x] Both configuration paths verified: `docker compose up` connects with DATABASE_URL set, and a second run with DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD instead (no DATABASE_URL) also connects successfully.

### Milestone 2: Core infrastructure, single region (2-3 days)
Tasks:
- [x] Modules: vpc, alb, ecs-service, rds, ecr per section 4.1. Compose in environments/prod.
- [x] Implement the VPC with all subnets using consistent `/27` netmasks for public, application, and database tiers across two AZs. The CIDR layout avoids overlap and reserves unused addresses for growth. Original plan called for `/28` database subnets; using `/27` everywhere simplifies the calculation and still provides adequate isolation.
- [x] Free S3 gateway endpoint enabled; optional paid interface endpoints disabled by default; one Regional NAT Gateway supports both AZs. Frankfurt confirmed to support Regional NAT. Ireland will be verified in M4.
- [x] Generate one ephemeral database password and write it through `password_wo` plus both regional SSM `value_wo` parameters; plaintext absent from plan output and state.
- [x] Resolve the latest common PostgreSQL 18 minor and compatible smallest Graviton class. Resolved version: PostgreSQL 18.4, instance class: db.t4g.micro. DR region resolution deferred to M4.
- [x] Use an explicit two-phase M2 deployment: foundation apply (`deploy_service = false`) creates ECR and supporting infrastructure; image pushed by immutable digest; service apply (`deploy_service = true`) creates the real task definition and ECS service from that digest.
- [x] ECS service with circuit breaker enabled per 4.7. Circuit breaker rollback test deferred to M3.
- [x] App pushes OTLP metrics to an internal OTel Collector; no public /metrics endpoint.
Acceptance criteria:
- [x] Starting from no workload resources, the documented M2 sequence completes successfully: foundation apply, image push, then service apply. Three-phase sequence recorded in evidence (foundation, image-build, service-deploy).
- [x] App reachable via ALB DNS, /status shows checks flowing (google.com and github.com up).
- [x] Post-apply smoke test verifies `/healthz`, `/status`, and `/` through the ALB.
- [x] Kill one task manually: ALB marks target unhealthy, ECS replaces it, service recovers without intervention. Replacement task provisioned within 30 seconds.
- [x] Verify Fargate task AZ distribution with evidence (one task in eu-central-1a, one in eu-central-1b). Stopping all tasks in one AZ is deferred, since Fargate auto-spread is best-effort, not configurable, and the plan states this is verified with evidence rather than configured.
- [x] Regional NAT spans both AZs; removing the NAT route affects both AZs simultaneously. Documented as a shared-NAT trade-off with per-AZ zonal fallback available. Full isolation test would require per-AZ NATs which contradicts the explicitly chosen Regional NAT design.
- [x] Database unavailability tested through RDS Multi-AZ failover: app lost connectivity for approximately 63 seconds, ALB returned errors, app reconnected automatically after failover completed. Structured logs identify DB dependency without leaking credentials.
- [x] RDS is Multi-AZ verified via API, then forced failover via reboot-db-instance. Application-visible downtime: approximately 63 seconds.
- [x] RDS automated backups have `backup_retention_period = 7`, storage encryption enabled, deletion protection = false (documented demo-only setting), skip_final_snapshot = true. PostgreSQL 18.4, db.t4g.micro.
- [x] ECS uses CPU 256, memory 512, Fargate LINUX/ARM64 platform, deployment circuit breaker with rollback, desired count 2, two private subnets, immutable ECR image digest.
- [x] ECR lifecycle policy retains only the last 10 images. Repository scan-on-push enabled, tag mutability = IMMUTABLE.
- [x] Security group chain verified: ALB(80 public) → ECS(8080 from ALB) → RDS(5432 from ECS). Direct internet access to task IPs and DB is blocked by security group configuration.
- [x] IAM policies: ECS task execution role scoped to one SSM parameter ARN. `kms:Decrypt` uses region-scoped key prefix (`Resource = "arn:aws:kms:*:926883320788:key/*"`), a documented exception per Hard Rule 7. Checkov scan deferred to M3 CI pipeline.
- [x] All taggable resources expose required tags. No untaggable resource types found.
- [x] Every module (vpc, alb, ecs-service, rds, ecr) has a README with inputs, outputs, one-sentence design intent, and cost notes per Hard Rule 10.
- [x] Apply-to-healthy wall time recorded: phase 1 approximately 9 minutes, phase 2 approximately 30 seconds. Environment rebuild time claim: 10 minutes.
- [x] Infracost unable to parse local module paths; pre-commit scan for bootstrap returned 0 EUR. Actual session cost will be reported via AWS Cost Explorer post-session.

### Milestone 3: CI/CD, monitoring, deployment safety (2 days)
Tasks:
- [x] app.yml workflow: test, build, push immutable image to ECR (OIDC federation for GitHub Actions role, no long-lived AWS keys), register/deploy the reviewed task definition, and update ECS service. Terraform itself (foundation and service applies, VPC/ALB/ECS/RDS/ECR) continues to be run manually (`terraform apply`) through M3 and M4 so DR work isn't blocked on CI tooling. **Deferred to M5:** terraform.yml workflow (fmt-check, validate, tflint, checkov, Infracost diff, plan-on-PR comment; approval-gated `workflow_dispatch` apply/destroy jobs); see M5 tasks. Workflow file written and validated (checkov, actionlint via pre-commit); not yet exercised by a real GitHub Actions run pending PR merge to main.
- [x] monitoring module: OTel Collector, Prometheus, and Grafana as ECS services per 4.6.
- [x] Alerting: CloudWatch alarms + SNS + EventBridge rule per 4.6.
Acceptance criteria:
- [x] A code-only app change: app.yml builds, tests, pushes an immutable image to ECR via OIDC, and updates the running ECS service to the new task definition revision, with zero manual AWS steps after workflow approval. Terraform-managed infrastructure continues to be applied manually via `terraform apply`/`terraform plan` for M3 and M4. Verified 2026-07-17: GitHub Actions run 29540534462 completed successfully end to end; task definition revision 5 was registered by the assumed OIDC role and the service reached steady state on the CI-built image (digest tagged with the merge commit SHA).
- [x] Broken-image demo: pushed an image that exits on start; provider-supported circuit breaker defaults tripped, rollback completed, SNS delivery confirmed (after fixing a topic-policy bug), service stayed healthy on old revision throughout. Measured rollback duration (update-service to rollback-initiated): ~3m58s first run, ~3m01s second run. See `docs/milestone-3-evidence.md`.
- [x] Grafana dashboard shows live data during a demo session. Verified via `aws ecs execute-command` into the Grafana task: `/api/health` ok, "Sentinel" dashboard provisioned and searchable, Prometheus datasource configured and default.
- [x] Verify OTLP metrics flow from app through collector to Prometheus; confirm the Grafana dashboard shows live check data during a demo session. Confirmed via live Prometheus query through the same exec channel: `sentinel_target_up{target="https://github.com"}=1`, `sentinel_target_up{target="https://www.google.com"}=1`.
- [x] Repeat the controlled database-unavailable test after monitoring is installed; verify ALB/ECS/RDS alarms and SNS notification delivery, then verify alarms recover when the database returns. Used a plain `reboot-db-instance` (not Multi-AZ forced failover, already proven in M2) to control cost. `/healthz` returned one 503 then recovered within ~10s; app logs show clean `db ping failed` / `database system is starting up` errors with no credentials leaked; SNS delivery separately confirmed via the ECS running-task-count alarm (see below).
- [x] Verify every primary-region monitoring requirement from section 4.6 exists and produces evidence: ALB 5xx, healthy host count, ECS running task count, RDS CPU, RDS free storage all exist and are OK (`aws cloudwatch describe-alarms`). SNS subscription delivery: alarm state forced to ALARM/OK confirmed "Successfully executed action" in alarm history (after fixing the topic policy). ECS `SERVICE_DEPLOYMENT_FAILED` EventBridge notification: confirmed via a temporary catch-all debug rule that the real event uses `detail.eventName` (not `eventType`, which is only a severity level); fixed the rule and reconfirmed `TriggeredRules=1` on the real Terraform-managed rule. SNS email subscription was `PendingConfirmation` at first writing; the project owner confirmed it on 2026-07-17 (verified via `aws sns list-subscriptions-by-topic` showing a real subscription ARN).
- [x] Monitoring module README per Hard Rule 10: inputs, outputs, one-sentence design intent.

### Milestone 4: Disaster recovery (2-3 days)

**Status 2026-07-17 (end of session):** prod's workload resources had been deleted to save cost; this session rebuilt prod from zero, built out the full DR side (Route53 delegation, ARC), ran a real PITR restore drill, and ran a real failover rehearsal end to end — disaster declared, replica promoted, DR scaled up, ARC toggled, traffic verified live on DR, RTO/RPO measured. See `docs/milestone-4-evidence.md` for full detail: two state-reconciliation incidents, a safety-rule semantics bug, a `failover.sh` bug, and a `measure.sh` bug, all caught and fixed live rather than glossed over. Every task and acceptance criterion below is checked off **except** the final topology reset (failback), which was intentionally stopped mid-way per explicit project-owner instruction — prod had been rebuilt as a temporary replica of DR (the safe reverse-replication leg) and verified, then the project owner asked to stop there and tear everything down to save cost rather than finish promoting prod back and rebuilding DR's replica in this session. **All AWS resources for this milestone were destroyed at the end of this session.** Next session starts from zero again — this is not a resume-in-place; see `docs/milestone-4-evidence.md`'s final section for exactly what needs re-doing.

Tasks:
- [x] Confirm Regional NAT availability in eu-west-1 before the DR VPC apply. Confirmed by the DR apply itself succeeding: `module.vpc.aws_nat_gateway.main` (availability_mode=regional) created in eu-west-1 without issue.
- [x] Resolve the latest common PostgreSQL 18 minor across eu-central-1 and eu-west-1 and require it to match the prod instance's running version before replica creation, per section 4.1. Implemented as a Terraform `check` block (`environments/dr/main.tf`) comparing `data.aws_rds_engine_version` in eu-west-1 against prod's `rds_engine_version` output via remote state; both resolved to `18.4`.
- [~] Upgrade and re-lock tooling at milestone start. `terraform init -upgrade` run for prod and dr: AWS provider already at latest `~> 6.0` (6.55.0), `random` at 3.9.0, no lock file changes needed. Local Terraform CLI is 1.15.5; latest patch 1.15.8 was not installed (a local binary upgrade, left to the project owner rather than done unprompted).
- [x] Create the Route53 hosted zone `sentinel.sagaruprety.com.np`, add its NS delegation records to the existing Cloudflare `sagaruprety.com.np` zone, and publish `status.sentinel.sagaruprety.com.np`. Zone created (`environments/dr/route53.tf`, zone ID `Z05244901B71SBS0IXLFG`) and NS delegation added via the Cloudflare MCP server in a separate session (its tools don't register in the session that adds the server — see `docs/cloudflare-mcp-setup.md`). Verified: `dig NS sentinel.sagaruprety.com.np` returns the Route53 nameservers; `status.sentinel.sagaruprety.com.np` published as a live ARC-gated record (below) resolving through Route53, confirmed serving prod's `/healthz` with a 200 through the actual domain.
- [x] Provision Route53 ARC routing controls only for the drill and verify the `$2.50/cluster-hour` cost. Applied with explicit project-owner go-ahead on the cost. `terraform/modules/route53-failover` created (cluster, control panel, 2 routing controls, 2 safety rules, 2 RECOVERY_CONTROL health checks, 2 detection-only HTTP health checks, 2 failover records). Not yet torn down — remains billing at $2.50/cluster-hour until the project owner tears it down after the drill.
- [x] environments/dr composing the same modules: VPC with free S3 gateway endpoint, interface endpoints disabled, ALB, ECS (desired_count 0), ECR replication. Applied: 78 resources, `terraform plan` shows no drift.
- [x] Extend the monitoring module into eu-west-1 for DR ALB, ECS, and RDS metrics plus the ECS deployment-failure EventBridge rule. Applied via the same `monitoring` module reused in the dr environment. Note: the module bundles these CloudWatch alarms together with the full OTel/Prometheus/Grafana Fargate stack (no split option existed); running that stack always-on in a pilot-light DR region was a real cost tradeoff (~$25-30/mo) the project owner explicitly approved rather than something decided unilaterally.
- [x] Cross-region read replica (single-AZ, `db.t4g.micro`, read from prod's own resolved class rather than hardcoded) in eu-west-1 plus `aws_db_instance_automated_backups_replication` with `retention_period = 7`. Required extending the `rds` module (`replicate_source_db_arn`, `kms_key_id` variables) since it only supported standalone instances before. Both mechanisms applied and verified — see evidence doc for lag and retention numbers.
- [~] Validate the write-only SSM credential lifecycle across replica creation, password rotation versioning, and promotion. The DR-region SSM parameter (`aws_ssm_parameter.database_password_dr`, write-only, created via the `aws.dr` provider alias in prod's state) is wired to the DR task's execution role with the same single-ARN-scoped `ssm:GetParameters` pattern as prod. Rotation-across-regions and promotion-time behavior are not yet exercised — that requires the actual drill (failover.sh), not yet run.
- [x] Route53 health monitoring and operator-gated traffic switching per 4.5. Two RECOVERY_CONTROL health checks gate the two failover records — DNS reflects only the ARC control's manual state, never raw ALB health, so no automatic routing to zero-capacity DR is possible by construction. Two plain-HTTP detection-only health checks (`/healthz`, `failure_threshold=3`) exist for evidence/alarming and are not wired to any record.
- [x] Scripts: `simulate-disaster.sh`, `failover.sh` (replica promotion path), `failback.sh`, `measure.sh`. Written, executable, and now all executed for real in the rehearsal below. `failover.sh` had a real bug (see acceptance criteria below) fixed mid-rehearsal; `measure.sh` had a real `to_epoch` bug (BSD `date` choking on fractional-second timestamps) fixed the same way.
- [x] `docs/architecture.md` documents prod-first apply, DR-first destroy, non-secret remote-state dependencies, bootstrap-state regional dependency, promotion and ECS drift, and reconciliation procedure.
- [x] runbook-failover.md. Written with real measured numbers from the rehearsal below, not placeholders.
Acceptance criteria:
- [~] Starting from no workload resources, apply prod foundations first, publish and verify the immutable image in prod ECR, wait for ECR replication and verify the same digest in eu-west-1, apply the prod service, then apply DR with desired_count 0. Prod and DR sequence both completed and verified (see evidence doc). One real gap found and fixed: the image had been pushed to prod ECR *before* replication was configured, so it never backfilled to eu-west-1 automatically (AWS only replicates images pushed after the replication rule exists) — required an explicit re-push to trigger it. Re-verified the exact digest present in both regions afterward.
- [x] Read replica in eu-west-1 shows replication lag under 30 seconds at demo load. Measured 10-17s via CloudWatch `ReplicaLag` after initial catch-up.
- [x] Replicated automated backups visible in eu-west-1 with a 7-day retention window; confirm the retention matches the primary. Confirmed via `aws rds describe-db-instance-automated-backups --region eu-west-1`: retention 7, status `replicating`.
- [x] Execute one isolated PITR restore in eu-west-1 into a new, separate DB instance. Restored from the replicated automated backup (`use-latest-restorable-time`) into a throwaway instance with temporary public networking; verified known pre-corruption rows present via `docker run postgres:18-alpine psql` and the SSM-stored password; measured 12m11s restore duration; observed RPO ≈11m59s (corruption point vs. newest restored row — section 4.3 sets no fixed PITR target, measured as-is); deleted the instance and its temporary subnet group/security group, confirmed removal via `DBInstanceNotFound`/`DBSubnetGroupNotFoundFault`/`InvalidGroup.NotFound`. See `docs/milestone-4-evidence.md`.
- [x] Recovery rehearsal of `failover.sh` promotes the replica to a working standalone database whose data includes checks written in the primary shortly before the rehearsal; calculate observed RPO against the 60-second target. Executed for real with explicit go-ahead. `failover.sh` hit a real bug live: its jq render of the task definition included `taskRoleArn: null` (the app task has no task role, only an execution role), and `register-task-definition` rejects a literal null for a string field. Fixed (`with_entries(select(.value != null))`) and continued the rehearsal manually from the already-completed promotion rather than re-running the whole script (promotion is not repeatable). Replica promoted (`ReadReplicaSourceDBInstanceIdentifier` → `null`, confirming standalone), DR scaled to 2/2 healthy, verified writing fresh data via `/status`. Replica lag measured continuously before promotion was 10-17s all session — well under the 60s target — and is the honest RPO basis; a post-promotion "newest row in DR" check (as `measure.sh` computes) is structurally unable to detect the real data-loss window once DR resumes writing new checks within seconds, which is exactly what happened here (see `docs/milestone-4-evidence.md`).
- [x] Traffic remains on primary while DR is unready, then switches only after the promoted database accepts writes and DR ALB targets are healthy. Exercised for real, in that order: prod served traffic (confirmed 503 once actually down) while DR sat at desired_count=0; only after `failover.sh`'s promotion, DR health check, and write verification did the ARC toggle happen, as a separate deliberate step.
- [x] ARC behavior is explicitly verified: all sub-claims now confirmed live, including the previously-untested one. Toggled primary Off / dr On via a single atomic `update-routing-control-states` call (both changes evaluated together, never passing through an invalid both-off or both-on intermediate state). Route53's `HealthCheckStatus` CloudWatch metric flipped (primary 1→0, dr 0→1) about a minute after the toggle — real propagation latency, not instant — and `dig` against a Route53 nameserver directly then returned DR's exact ALB IPs (not prod's), with a live `curl` through `status.sentinel.sagaruprety.com.np/healthz` returning 200 served by DR.
- [x] Route53 health checks use the documented `/healthz` path and deliberate failure threshold; demonstrate that one transient failed probe does not route traffic and that health monitoring remains detection-only until the operator toggles ARC. Two HTTP health checks (`/healthz`, `failure_threshold=3`) exist for detection/evidence and are architecturally incapable of routing traffic — they aren't referenced by either failover record, only the RECOVERY_CONTROL health checks are. Confirmed both regions' detection health checks tracked reality correctly through the drill (prod's CloudWatch alarms went to `ALARM` on `healthy-hosts`/`running-tasks` the moment prod actually went down; DR's stayed `OK` throughout its own activation).
- [x] After measured service recovery, convert the promoted single-AZ DR database to Multi-AZ, verify the standby is available, and report the reduced-availability window separately from RTO. Converted via `modify-db-instance --multi-az --apply-immediately`; see evidence doc for the measured conversion window, reported separately from the 736s RTO above (Multi-AZ conversion is a post-recovery hardening step, not part of recovery itself).
- [x] Before declaring drill readiness, verify DR prerequisites match primary: ECR image digest present in eu-west-1 (confirmed), DR task definition matches prod's reviewed configuration (true by construction), SSM parameter metadata/versions current (confirmed). Service quota sufficiency was implicitly confirmed by the rehearsal itself succeeding — DR scaled to 2/2 with no quota error.
- [x] Verify DR monitoring after activation: healthy-host, running-task, database, and deployment-failure signals exist in eu-west-1 and the notification path works. All five DR alarms read `OK` post-activation; prod's alarms correctly flipped to `ALARM` on exactly the two signals that should trip (`healthy-hosts`, `running-tasks`), confirming the monitoring reflects real state on both sides, not just DR's.
- [x] `terraform plan` after scripted promotion and scaling clearly exposes drift; intended post-drill configuration is reconciled before destroy. Confirmed: plan shows `desired_count` wanting to revert 2→0, the task definition revision wanting to revert 2→1, and the promoted RDS instance showing Terraform wanting to re-assert `replicate_source_db` (which would attempt to recreate it as a replica if blindly applied — not done). Reconciliation is the failback procedure below, not a blind `apply`.
- [ ] After the rehearsal, rebuild the intended primary-to-DR replica topology, wait until the new replica is available, verify lag and a known row, reset ECS desired counts and ARC controls, and record reset duration and cost. This reset is required before M5. **Intentionally stopped mid-way, not blocked:** prod was rebuilt as a temporary replica *of* DR (reverse direction, first leg of the safe failback path) and verified catching up with correct backup retention; the project owner then explicitly asked to stop here and tear resources down to save cost rather than complete the reverse-then-promote-then-rebuild sequence in this session. **All resources destroyed afterward** (see below) — resuming this next session means re-applying prod and DR from zero again first, then finishing this reset before the environment is M5-ready. Next session starts from: apply prod foundation → service → DR foundation (same sequence as this session's opening), then repeat the reset sequence: promote prod (still configured as a replica of DR's ARN at time of teardown) — except DR no longer exists post-destroy, so this specific half-finished state does *not* carry forward; treat next session as a fresh M4 environment build, not a resume-in-place.
- [x] The route53-failover module has a README per Hard Rule 10: inputs, outputs, one-sentence design intent, and a cost note on the ARC cluster's per-hour billing.

### Milestone 5: The drill, the evidence, the writeup (2 days)
Tasks:
- [ ] Deferred from M3: terraform.yml workflow, fmt-check, validate, tflint, checkov, Infracost diff, and plan on PR with useful output posted as a PR comment. Apply and destroy are separate `workflow_dispatch` jobs protected by GitHub environment approval; merging code must not create infrastructure automatically. The approved deploy workflow automates the M2 sequence from zero: foundation apply, build and push immutable Sentinel image, then service apply with that digest.
- [ ] Full disaster drill end to end: traffic on primary -> simulate-disaster.sh -> detection and declaration -> operator invokes failover.sh -> replica promotion -> DR readiness verification -> ARC traffic switch -> DR serving traffic. measure.sh captures phase timestamps from the first confirmed user-visible outage. Run at least twice; report end-to-end RTO, operator-invocation automation duration, and RPO for both runs, not just the better run.
- [ ] Between the two drills, execute the documented topology reset: rebuild the primary-to-DR read replica relationship, wait for availability, verify replication lag and a known row, restore primary/DR ECS desired counts, reset ARC controls, and confirm all readiness checks before beginning the second drill. Record reset time and cost separately from RTO.
- [ ] Query the checks table in DR for the outage window; screenshot/export as evidence.
- [ ] Record terminal + Grafana + status page side by side; produce demo.gif (short) and demo.mp4 (full).
- [ ] docs/postmortem.md: separate timelines for ECS replacement, RDS Multi-AZ failover, deployment rollback, and regional DR; detection, impact, measured RTO/RPO against targets, and improvements such as warm standby trade-offs and automation gaps.
- [ ] Confirm every row of the resilience test matrix (4.8) was executed at its assigned milestone with evidence retained; all ten rows are mandatory, none are documentation-only. If any row could not be executed, say so explicitly with the reason and do not imply the matrix covers every possible failure.
- [ ] docs/architecture.md with diagram (mermaid in-repo plus one exported PNG).
- [ ] Final README: pitch, diagram, demo GIF at top, measured RTO/RPO, actual Cost Explorer session cost and duration, why infrastructure is ephemeral, and design decisions (two-AZ Regional NAT with per-AZ fallback, optional endpoints, desired_count 0 vs not-deployed, ARC data-plane traffic switch, provider-supported circuit breaker behavior, secret lifecycle, state dependency, and failback model), plus complete run instructions.
Acceptance criteria:
- [ ] A PR with a Terraform change shows plan and Infracost information as a comment; an approved manual workflow applies the reviewed commit. From no workload resources, one approved deployment workflow creates foundations, publishes the image, creates the ECS service, and reaches healthy Sentinel tasks without placeholder containers or manual image steps. A later code-only change deploys to ECS with zero manual AWS steps after workflow approval.
- [ ] README contains only measured numbers, no estimates presented as measurements.
- [ ] A stranger can rebuild the entire project from the README in one sitting.
- [ ] Total AWS bill for the whole build reviewed and stated in the README cost section.
- [ ] Failback is either executed and measured or explicitly documented as unexecuted; no claim implies it was tested when it was not.

## 7. Timeline

Roughly three to four weeks part-time: M0+M1 week 1, M2+M3 week 2, M4+M5 week 3-4. Hard cap on app work (1 day). M2 is tight at 2-3 days given Regional NAT, forced RDS failover, write-only credential wiring, and dual-region PostgreSQL version resolution; expect it to run toward the high end. M4 is optimistic at 2-3 days once it includes cross-region RDS with verified retention, one executed PITR restore, ARC cluster lifecycle, Cloudflare delegation, four scripts, and failback design; budget 4-5 days. If any milestone runs 50 percent over, cut optional scope (HTTPS, hosted Grafana on ECS, failback automation) before extending time.

## 8. CV Bullet (final, use only after Milestone 5)

"Designed and demonstrated a highly available AWS workload (personal project): Terraform-provisioned ECS Fargate across two AZs with Multi-AZ RDS, CloudWatch and OpenTelemetry monitoring, GitHub Actions CI/CD with automated rollback, and cross-region pilot light disaster recovery with Route53 failover, achieving a measured RTO of X minutes with point-in-time recovery."

Replace X with the measured value. Keep the personal project label.

## 9. Out of Scope (do not let agents add these)

Custom auth, user accounts, alerting rules inside the app, Kubernetes/EKS, multi-account setups, service mesh, HTTPS/ACM (optional stretch only), AI/LLM features, any always-on infrastructure beyond the bootstrap state bucket.
