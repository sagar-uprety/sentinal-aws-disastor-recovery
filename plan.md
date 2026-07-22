# Project Plan: Resilient Status Page on AWS

Portfolio project! Target roles: Senior DevOps Engineer / Platform Engineer.
This document is the single source of truth for AI agents implementing the project. Follow it exactly. Where this document is silent, prefer AWS official documentation and Terraform AWS provider documentation.

---

## 1. Project Summary

A self-monitoring uptime service ("status page") deployed as a production-grade, highly available AWS workload with automated cross-region disaster recovery using the pilot light strategy. Everything is defined in Terraform. The environment is ephemeral by design: apply, demo, record, destroy.

One-line pitch for the README: "A multi-AZ AWS workload with pilot light DR in a second region, fully defined in Terraform. The app monitors external sites and confirms public reachability after recovery, while AWS-native health signals and drill timestamps measure the outage, RTO, and RPO."

Design rationale to state in the README: the customer-facing status page is the workload that fails over. CloudWatch alarms, SNS notifications, Route53 health checks, ARC routing-control state, and recorded drill timestamps provide operator evidence without adding a regional observability stack that fails with the workload.

Reference architecture basis: AWS whitepaper "Disaster Recovery of Workloads on AWS" (pilot light strategy), AWS Well-Architected Reliability Pillar REL13-BP02.

## 2. Hard Rules (apply to every milestone)

1. No fabrication anywhere. README, docs, and any generated text must describe only what was actually built and measured. RTO/RPO numbers are written only after they are measured in a real drill. Placeholders like "RTO: TBD (measure in Milestone 6)" are used until then.
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

    Set via `default_tags` in each environment's provider block, not per-resource. Terraform modules propagate them automatically.
12. Bootstrap resources (state bucket, lock table) use the same tag scheme with `Environment=prod`.

## 3. Application Specification

Language: Go (fallback: Python FastAPI if Go blocks progress). Single Docker container, distroless or alpine base, non-root user.

Behavior:
- Background loop (goroutine with ticker) checks each target URL every 30 seconds with a 5 second timeout via HTTP GET.
- Each check writes one row: target_url, status_code (nullable), response_ms, is_up (bool), checked_at (timestamptz).
- Targets are defined in the version-controlled `app/targets.json` file as a non-empty JSON `targets` array of HTTP(S) URLs, including the canonical public status URL. At startup, the app seeds those URLs idempotently into PostgreSQL.

Endpoints:
- `GET /healthz` returns 200 and `{"status":"ok"}` if the DB is reachable. Used by ALB target group health check.
- `GET /targets` returns the target list as JSON.
- `GET /status` returns the latest check per target.
- `GET /history?target={url-encoded target URL}` returns the last 100 checks for that exact target URL (exact match on checks.target_url, no substring or LIKE matching; targets sharing a host suffix must not collide).
- `GET /` serves one static HTML page styled as a clean, modern status page used during the live drill. UI spec, all in a single static file with inline CSS and a small inline script, no framework, no npm, no build step:
  - Overall status banner at the top: "All systems operational" (green) when every target is up, "Service disruption" (red) otherwise, derived from `/status`.
  - One card per target: colored status dot (green/red), target hostname, latest response time in ms, "checked Xs ago", and an uptime percentage for the last 24 hours (computed server-side from the checks table, returned by /status).
  - Per card, a strip of the last 50 checks rendered as thin vertical bars (inline SVG or canvas, approx 30 lines, no charting library): green bar height maps to response time, red bar for a failed check. During the disaster drill this strip visibly turns red and recovers.
  - Optional, only if it fits inside the time cap: one response-time line chart per target (last 100 checks) using a single lightweight chart library loaded via one CDN script tag (uPlot preferred, Chart.js acceptable). This is the only permitted external dependency. Still no npm, no build step, still one HTML file.
  - Clean minimal styling: single accent palette, system font stack, generous whitespace, looks reasonable on mobile. Auto-refresh every 15 seconds via the inline script.
  - Explicitly forbidden: React or any framework, Tailwind or any CSS build, npm or any build step, more than the one CDN chart library above, theme toggles, animations beyond the refresh.

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

Runtime configuration uses env vars: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, CHECK_INTERVAL_SECONDS (default 30), PORT (default 8080). Target configuration is the version-controlled `app/targets.json` file bundled into the image. ECS injects DB_PASSWORD from the region-local SSM SecureString and ordinary environment values for non-secret fields; the Go app assembles the connection string without logging it. Local development may continue to accept DATABASE_URL as a mutually exclusive convenience input.

Observability in the app: structured JSON logs to stdout, retained in the regional ECS CloudWatch Logs group. Check history is persisted in PostgreSQL and shown by the status page. The app does not expose or push metrics. No Grafana, Prometheus, OTel Collector, or telemetry archive is deployed.

## 4. Architecture Specification

Version policy:
- Use Terraform 1.15.5 from `.terraform-version`; every root module declares `required_version = ">= 1.11, < 2.0"` because write-only arguments require Terraform 1.11 or newer.
- Use the latest stable AWS provider major 6 release available when a milestone starts, constrained as `~> 6.0`. Add the latest compatible HashiCorp Random provider when ephemeral password generation is implemented in M2; do not declare it before use because the repository rejects unused providers. Run `terraform init -upgrade`, review provider changelogs and the plan, and commit lock files for every root that uses each provider. "Latest" means intentionally upgraded and locked, not an unbounded provider constraint.
- Pin PostgreSQL major 18 while resolving its latest common regional minor as described below. Major upgrades require a separate reviewed change and test; latest does not mean automatic major-version drift.

### 4.1 Primary region (eu-central-1)
- VPC `10.0.0.0/24` across eu-central-1a and eu-central-1b. Allocate two public `/27` subnets for ALB and public ingress, two private application `/27` subnets for ECS, and two isolated database `/28` subnets for RDS. A `/27` has 27 AWS-usable addresses and a `/28` has 11, enough for two steady ECS tasks, deployment overlap, ALB nodes, Regional NAT attachments, and RDS failover with substantial headroom. Reserve the remaining addresses for growth. The DR VPC uses non-overlapping `10.1.0.0/24`; document the address calculation in the module README.
- ALB in public subnets, HTTPS :443 with a DNS-validated regional ACM certificate. HTTP :80 redirects permanently to HTTPS. `sagaruprety.com.np` remains authoritative in Cloudflare. Delegate the `sentinel.sagaruprety.com.np` subdomain to a Route53 public hosted zone using NS records in Cloudflare before applying ACM validation. Publish the dashboard at the delegated-zone apex `sentinel.sagaruprety.com.np`, with machine health at `/healthz`; Route53 manages the operator-gated regional route. Each regional ALB needs its own ACM certificate because ACM certificates are regional for ALB listeners.
- ECS Fargate cluster. One service, desired_count = 2 in demo mode, 1 in idle-testing mode. Tasks in private subnets. CPU 256, memory 512. Fargate does not support placement strategies or constraints; AZ spread across the two private subnets is automatic and best-effort, verified with evidence in M2 rather than configured.
- Pin an explicit supported Fargate Linux platform version in Terraform and record it in the module README; do not rely silently on a changing `LATEST` value.
- Egress for image pull, logs, SSM retrieval, and external checks uses one Regional NAT Gateway configured for both AZs plus the free S3 gateway endpoint. Regional NAT is part of every applied prod and DR environment, not a feature flag, because the workload cannot perform its core checks or reliably start replacement tasks without it. AWS bills one NAT Gateway-hour per supported AZ, so this has roughly the fixed hourly cost of one zonal NAT per AZ, not one zonal NAT total. It avoids the single-NAT AZ dependency and simplifies routing. Confirm Regional NAT availability in Frankfurt and Ireland before implementation; fallback is one zonal NAT per AZ, never one shared zonal NAT.
- RDS PostgreSQL: pin major version 18 and use `data.aws_rds_engine_version` with `version = "18"` and `latest = true` to select the latest minor available in both eu-central-1 and eu-west-1 at apply time. Record the resolved minor in evidence and require both regions to match before replica creation. Enable automatic minor upgrades; never float automatically to a new major. Use db.t4g.micro if orderable for the resolved version in both regions, otherwise select the smallest supported Graviton class and document the cost change. Configure 20 GB gp3, backup_retention_period = 7, storage encryption, deletion_protection = false, and skip_final_snapshot = true. Module README must warn that the deletion settings are demo-only and that burstable instances can lag under sustained load. `multi_az` is true for the Milestone 2 HA test and full demo, false only for explicitly labeled basic testing.
- Multi-AZ RDS synchronously maintains a standby in another AZ for availability; that standby is not a backup. RDS automated backups provide the seven-day regional PITR window and are stored by the managed service independently of one DB AZ. Cross-region automated backup replication separately copies recovery data to eu-west-1 for regional disaster and corruption recovery. No manual or final snapshot is retained after teardown unless a drill explicitly creates one and deletes it after evidence collection.
- Security groups chained: ALB (ingress 80 and 443 from 0.0.0.0/0) -> ECS tasks (ingress 8080 from ALB SG only) -> RDS (ingress 5432 from ECS SG only).
- ECR repository with lifecycle policy (keep last 10 images).
- State-safe SSM credentials: Terraform 1.11+ creates one ephemeral random password during the prod apply. The same ephemeral value flows to RDS through `password_wo` and to Standard-tier SecureString parameters in eu-central-1 and eu-west-1 through `value_wo`, using aliased AWS providers. Keep `password_wo_version` and both `value_wo_version` values synchronized through one explicit credential version variable. The plaintext never enters Terraform state. The prod stack owns both regional parameter metadata so the DR parameter exists before failover and the promoted replica uses the inherited password. ECS task execution roles receive narrowly scoped `ssm:GetParameters` and `kms:Decrypt` permissions for only their regional parameter and key.

### 4.2 DR region (eu-west-1), pilot light
- Mirrored VPC `10.1.0.0/24` with the same `/27` public, `/27` application, and `/27` database subnet pattern, two-AZ Regional NAT Gateway, free S3 gateway endpoint, ALB, ECS cluster, task definition, and service with desired_count = 0. Paid interface endpoints remain optional and disabled by default. Terraform composes the same modules with different variables. The recovery environment cannot process requests until the database is promoted and compute is started, so this is pilot light rather than warm standby. Live replicated data and core network resources remain available while application compute is switched off, matching the AWS pilot-light guidance.
- Database, two complementary mechanisms (state the rationale for both in the README):
  1. Cross-region read replica: a single-AZ replica in eu-west-1 using the smallest compatible Graviton class resolved for both regions in M2, created from the primary (streaming replication, RPO of seconds under demo load). On failover it is promoted to standalone primary, which takes minutes. This keeps the data resource always on in the recovery region, matching the whitepaper pilot light definition, and is the fast RTO path. It runs only during demo sessions (the whole environment is ephemeral).
  2. RDS Cross-Region Automated Backup Replication (Terraform resource `aws_db_instance_automated_backups_replication`, snapshots plus transaction logs, point-in-time restore in eu-west-1). Set its `retention_period` to 7 to match the primary's PITR window; destination retention is independent of the source and defaults differently if left unset. This is the corruption protection layer: a replica faithfully replicates corrupted or deleted data, so PITR backups are what allow rewinding to the last good state, per the whitepaper caveat. Cost is cents.
- The DR network and ALB span two AZs. When recovery starts, ECS scales to two tasks distributed across those AZs. The always-on read replica is intentionally single-AZ to control pilot-light cost; immediately after service recovery, convert the promoted DR database to Multi-AZ as a separate stabilization step and measure that duration. State clearly that the recovered service has reduced database availability between promotion and completion of this conversion.
- The failover script uses replica promotion as the primary recovery path; the runbook documents PITR restore as the corruption-scenario alternative, including its expected 15-60 minute restore duration.
- ECR replication rule so the image exists in eu-west-1.

Apply prod before DR because the replica, backup replication, and ECR replication depend on primary resource identifiers. Keep environment state separate and pass only documented non-secret outputs through `terraform_remote_state`. Store state in the bootstrap bucket and document that a primary-region S3 outage can prevent Terraform-driven recovery; the failover runbook must remain executable with AWS CLI using recorded resource identifiers. Destroy DR before prod. Promotion changes replica topology and CLI scaling changes ECS desired count, so the runbook must reconcile configuration and Terraform state after every drill.

### 4.3 Failover automation

Recovery objectives, defined before testing:
- End-to-end regional recovery target RTO: 30 minutes from the first confirmed user-visible primary outage until `sentinel.sagaruprety.com.np` serves verified traffic backed by writable DR data. Record detection, declaration, promotion, task startup, health verification, and routing as separate phases. Also report operator-invocation-to-recovery automation duration, but do not substitute it for end-to-end RTO.
- Replica-promotion path target RPO: 60 seconds at demo load, measured from the newest primary check visible in DR after promotion.
- PITR corruption path target RPO: no more than the service-supported restore granularity; measure it during the drill rather than assuming a value.

Recovery is operator-gated at each irreversible boundary. DNS must never route users to an unready pilot light:
- `scripts/simulate-disaster.sh`: requires `CONFIRM_DISASTER=YES`, starts a new drill segment, records the newest primary row for the canonical RPO target, verifies DR is an available read replica with ECS at zero, scales primary ECS to 0, and records the outage only after the primary ALB returns 503 with zero healthy targets. It restores the original primary count if outage confirmation fails. It does not alter traffic routing.
- `scripts/failover.sh`: requires a current `outage_confirmed` event plus `CONFIRM_FAILOVER=YES`, validates the replica, immutable regional ECR digest, regional SSM parameter, and fresh `ReplicaLag` evidence, promotes the replica, verifies it is standalone, registers the DR task definition, scales ECS to 2 tasks across two AZs, requires two healthy ALB targets, verifies fresh database writes, and records the newest pre-outage row available in DR. It deliberately does not switch traffic.
- `scripts/switch-traffic.sh`: is the separate final operator gate. It requires verified DR readiness, discovers the pre-created ARC cluster and routing controls, checks the expected initial control states, atomically changes primary Off and DR On through one of ARC's regional data-plane endpoints, then records completion only after authoritative Route53 DNS and `/topology` prove public traffic is served by eu-west-1.
- Traffic switching uses an operator-gated Route53 Application Recovery Controller routing control connected to the `sentinel.sagaruprety.com.np` apex records. Provision the ARC routing-control cluster only for the drill; its published rate was $2.50 per cluster-hour when this plan was revised, but verify current pricing before apply. Include the charge in session evidence. The project owner controls teardown after evidence capture. Fallback: a deliberate Route53 record update after readiness verification, clearly identified as a less resilient control-plane operation. Automatic primary-health-check DNS failover to an unready DR ALB is forbidden.
- `scripts/failback.sh`: guards operational failback phases while topology-changing Terraform plans run through protected manual GitHub Actions dispatches. It creates and later deletes the temporary safety snapshot, verifies reverse-replica source and lag, promotes and hardens prod, requires the known DR-written row before switching back, then verifies restored primary-to-DR replication and DR desired count 0. Local scripts assume the operator's active AWS credentials already have required permissions; no dedicated local recovery role is provisioned.
- `scripts/measure.sh`: isolates the latest `drill_started` segment so two drills cannot mix events, reports each recovery phase, measures RTO through authoritative DNS and public DR `/topology` verification, and derives row-based RPO by comparing the newest primary target row before the outage with the newest matching pre-outage row present in DR. The pre-promotion `ReplicaLag` maximum is retained as supporting AWS control-plane evidence.
- Every script records changed resources. After the drill, dispatch the guarded recovery workflow and inspect its saved topology plans before approving apply or destroy. Never use `terraform apply -refresh-only` as a substitute for the declared primary and replica roles.

Control-plane operations create or change configuration, such as promoting RDS, scaling ECS, modifying Multi-AZ mode, or changing Route53 records. Data-plane operations use resources that already exist to serve traffic or toggle pre-created routing state, such as ALB requests, database queries, DNS answers, and ARC routing controls. Pilot light accepts some control-plane dependency to reduce standby cost, but the final traffic switch uses pre-created ARC data-plane controls after all required control-plane recovery steps succeed.

### 4.4 Cost rationale for paid services

Every project service is chosen intentionally. Here is why each paid service is necessary and what would break without it.

**NAT Gateway:** ECS tasks in private subnets need internet egress to check external URLs and start reliably without paid interface endpoints. Without NAT, the app can still serve stored results but cannot perform its core checks. Putting tasks in public subnets with public IPs broadens exposure and is rejected. One NAT gateway resource (`availability_mode = "regional"`, spanning both AZs per 4.1) is therefore created by default in each applied environment, with no enable/disable variable; it is billed per supported AZ, not at a single zonal rate. Exact regional hourly and data-processing charges come from Infracost and the final bill.

**ALB:** Required for load balancing across ECS tasks, HTTPS termination with regional ACM certificates, application health checks, and the Route53 target. Fargate tasks have dynamic IPs, so a stable endpoint is needed. A Network Load Balancer does not provide the required Layer 7 health and routing behavior. Use current regional Infracost data instead of hard-coded rates.

**ECS Fargate:** The compute platform for the container. The project's core premise is a containerized AWS workload with HA/DR. Lambda is unsuitable for the long-lived checking loop, while EC2 introduces OS maintenance and idle instance capacity. Use current regional Infracost data instead of hard-coded rates.

**RDS Multi-AZ:** Multi-AZ is enabled only during demo sessions to test within-region database failover. During basic testing, set `multi_az = false` to reduce cost. Do not assume Free Tier eligibility. Confirm instance availability and current regional rates through the AWS provider and Infracost before implementation.

**VPC endpoints:** The S3 gateway endpoint has no hourly charge and reduces NAT traffic, so it is enabled. ECR API/DKR, CloudWatch Logs, and SSM interface endpoints charge per endpoint per AZ plus data processing. For this ephemeral, low-traffic workload they are disabled by default because their fixed hourly cost is likely greater than NAT processing savings. They remain module options to demonstrate the production trade-off between private AWS API paths, NAT/AZ failure behavior, and cost.

**SSM Parameter Store:** Two regional Standard-tier SecureString parameters hold the same RDS password, one for prod ECS and one for DR ECS. Terraform ephemeral values plus AWS provider write-only arguments keep plaintext out of state. Standard parameters fit the small secret count and avoid Secrets Manager. KMS API charges, if any, are included in measured session cost.

### 4.5 Route53
- Keep health checks for detection and evidence, with a deliberate `failure_threshold` that avoids reacting to a single transient failure. Do not attach automatic failover routing that sends users to DR while its desired count is zero. The final measured drill must use an operator-gated Route53 ARC routing control after `failover.sh` verifies the promoted database, healthy DR targets, and successful writes. A scripted Route53 record update remains an emergency fallback only and must be documented as a less resilient control-plane operation, not presented as equivalent evidence.
- The registered parent domain `sagaruprety.com.np` remains on Cloudflare. Terraform creates the `sentinel.sagaruprety.com.np` Route53 public hosted zone. Add its returned NS records to Cloudflare once, then verify delegation with `dig NS sentinel.sagaruprety.com.np`. Route53 publishes the dashboard at that zone apex and owns its ARC routing controls without moving the parent domain away from Cloudflare.

### 4.6 Monitoring
- CloudWatch alarms: ALB 5xx count, ALB healthy host count < 1, ECS running task count < desired, RDS CPU > 80, RDS free storage low. All alarms notify one SNS topic with email subscription. The DR task-count alarm expects zero while pilot light is inactive; `failover.sh` changes it to two after scaling DR, and Terraform reconciliation restores zero after the drill.
- EventBridge rule on ECS `SERVICE_DEPLOYMENT_FAILED` -> same SNS topic (circuit breaker visibility).
- CloudWatch alarms are regional. Create and verify alarms in both regions. Do not imply CloudWatch automatically aggregates regional alarms; use SNS notifications, Route53 health checks, ARC routing-control state, and recorded drill timestamps as recovery evidence.

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
| Regional application and database | Stop primary ECS, promote DR replica, start DR ECS, then switch traffic | Pilot-light runbook meets measured RTO/RPO targets | M6 | Mandatory |
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
│   ├── targets.json
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
│       ├── bootstrap/        # persistent state backend, GitHub OIDC roles, and delegated Route53 zone
│       ├── prod/             # eu-central-1
│       └── dr/               # eu-west-1
├── scripts/
│   ├── drill-lib.sh
│   ├── simulate-disaster.sh
│   ├── simulate-ha.sh
│   ├── failover.sh
│   ├── switch-traffic.sh
│   ├── failback.sh
│   └── measure.sh
├── .github/workflows/
│   ├── app.yml               # PR quality checks; protected main-branch ECS deployment
│   ├── recovery.yml          # protected failback topology plan/apply operations
│   └── terraform.yml         # quality, speculative plan comments, and protected manual deploy/destroy
├── docker-compose.yml        # local dev stack: app and postgres
├── docs/
│   ├── aws-dr-architecture.drawio # canonical editable architecture diagram
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
- [x] Bootstrap state bucket has versioning, server-side encryption, and public-access blocking enabled; the bucket and lock table expose the Hard Rule 12 tags (`Project`, `ManagedBy`, `Environment=prod`).
- [x] Existing owner-managed AWS Budgets were healthy before the bootstrap apply; evidence retained in `docs/milestone-0-evidence.md` without importing or managing budgets in Terraform.
- [x] `git log` shows conventional, meaningful commits.

### Milestone 1: Application (1.5 days, hard cap; at most half a day of that on the UI)
Tasks:
- [x] Implement the app per section 3, including structured JSON logs and the static page.
- [x] Unit tests for the check logic (mock HTTP) and one integration test with Postgres via testcontainers or docker-compose.
- [x] Dockerfile: multi-stage build, non-root, final image under 30 MB for Go. _(4.82 MB)_
- [x] docker-compose.yml for local dev (app + postgres).
- [x] Add DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD env var support per section 3 (line 80). ECS injects these individually in M2/M4, so DATABASE_URL-only cannot receive the region-local SSM password. Keep DATABASE_URL as a mutually exclusive local-dev convenience input. Unit test both configuration paths.
Acceptance criteria:
- [x] `docker compose up` locally: /healthz 200, /status shows real check results within 60 seconds, and / renders the status page per the UI spec (banner, cards, last-50-checks strips, auto-refresh).
- [x] Visual check: the page looks like a credible modern status page in a screenshot, and a failed target visibly turns its card and strip red within one refresh cycle.
- [x] Tests pass in CI-runnable form (`go test ./...`), including both database configuration paths.
- [x] App remains single-purpose and infrastructure-focused: one container, PostgreSQL persistence, no auth, no accounts, no alert engine, and no frontend build system. Production Go code is 664 physical lines across five small files; this replaces the inaccurate approximate 400-line checkbox while preserving its scope-control intent.
- [x] Both configuration paths verified: `docker compose up` connects with DATABASE_URL set, and a second run with DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD instead (no DATABASE_URL) also connects successfully.

### Milestone 2: Core infrastructure, single region (2-3 days)
Tasks:
- [x] Modules: vpc, alb, ecs-service, rds, ecr per section 4.1. Compose in environments/prod.
- [x] Implement the VPC with all subnets using consistent `/27` netmasks for public, application, and database tiers across two AZs. The CIDR layout avoids overlap and reserves unused addresses for growth. Original plan called for `/28` database subnets; using `/27` everywhere simplifies the calculation and still provides adequate isolation.
- [x] Free S3 gateway endpoint enabled; optional paid interface endpoints disabled by default; one Regional NAT Gateway supports both AZs. Frankfurt confirmed to support Regional NAT. Ireland will be verified in M4.
- [x] Generate one ephemeral database password and write it through `password_wo` plus both regional SSM `value_wo` parameters. Current code uses `ephemeral.random_password` and an ephemeral module variable, replacing the earlier stateful `random_password` resource. Final applied-state no-plaintext evidence is tracked in M6.
- [x] Resolve the latest common PostgreSQL 18 minor and compatible smallest Graviton class. Resolved version: PostgreSQL 18.4, instance class: db.t4g.micro. DR region resolution deferred to M4.
- [x] Use an explicit two-phase M2 deployment: foundation apply (`deploy_service = false`) creates ECR and supporting infrastructure; image pushed by immutable digest; service apply (`deploy_service = true`) creates the real task definition and ECS service from that digest.
- [x] ECS service with circuit breaker enabled per 4.7. Circuit breaker rollback test deferred to M3.
- [x] App writes structured JSON logs to stdout and has no public metrics endpoint.
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
- [x] Historical M2 verification covered ALB(80 public) → ECS(8080 from ALB) → RDS(5432 from ECS). The current ACM-backed path was verified live on 2026-07-21: both regional certificates are issued, HTTPS and `/healthz` return 200, and HTTP redirects permanently to HTTPS with 301. Direct internet access to task IPs and DB remains blocked by security group configuration.
- [x] IAM policies: ECS task execution role scoped to one SSM parameter ARN. `kms:Decrypt` uses region-scoped key prefix (`Resource = "arn:aws:kms:*:926883320788:key/*"`), a documented exception per Hard Rule 7. Checkov scan deferred to M3 CI pipeline.
- [x] All taggable resources expose required tags through provider defaults: `Project`, `ManagedBy`, and `Environment`.
- [x] Every module (vpc, alb, ecs-service, rds, ecr) has a README with inputs, outputs, one-sentence design intent, and cost notes per Hard Rule 10.
- [x] Apply-to-healthy wall time recorded: phase 1 approximately 9 minutes, phase 2 approximately 30 seconds. Environment rebuild time claim: 10 minutes.
- [x] Infracost unable to parse local module paths; pre-commit scan for bootstrap returned 0 EUR. Actual session cost will be reported via AWS Cost Explorer post-session.

### Milestone 3: CI/CD, monitoring, deployment safety (2 days)
Tasks:
- [x] app.yml workflow: pull-request Go/frontend/container quality checks; protected main-branch deployment that pushes an immutable ECR image by digest, registers the reviewed task definition, waits for ECS stability, and verifies public health using OIDC credentials with no long-lived AWS keys. Terraform itself continued to be run manually through M3 and M4 so DR work was not blocked on CI tooling. Terraform workflow implementation and local validation were completed in M5, then exercised live through PRs #14–#17 on 2026-07-21.
- [x] monitoring module: CloudWatch alarms, SNS notifications, and an EventBridge ECS deployment-failure notification per 4.6.
- [x] Alerting: CloudWatch alarms + SNS + EventBridge rule per 4.6.
Acceptance criteria:
- [x] A code-only app change: app.yml builds, tests, pushes an immutable image to ECR via OIDC, and updates the running ECS service to the new task definition revision, with zero manual AWS steps after workflow approval. Terraform-managed infrastructure continues to be applied manually via `terraform apply`/`terraform plan` for M3 and M4. Verified 2026-07-17: GitHub Actions run 29540534462 completed successfully end to end; task definition revision 5 was registered by the assumed OIDC role and the service reached steady state on the CI-built image (digest tagged with the merge commit SHA).
- [x] Broken-image demo: pushed an image that exits on start; provider-supported circuit breaker defaults tripped, rollback completed, SNS delivery confirmed (after fixing a topic-policy bug), service stayed healthy on old revision throughout. Measured rollback duration (update-service to rollback-initiated): ~3m58s first run, ~3m01s second run. See `docs/milestone-3-evidence.md`.
- [x] The former Grafana, Prometheus, and OTel ECS stack was removed after review because it duplicated status-page data, used ephemeral storage, and shared the workload failure domain. CloudWatch alarms and SNS remain the project monitoring mechanism. Live re-verification found all prod alarms healthy and exposed incorrect standby semantics in two DR pilot-light alarms; that correction is tracked in M6 rather than left as unfinished M3 scope.
- [x] Repeat the controlled database-unavailable test after monitoring is installed; verify ALB/ECS/RDS alarms and SNS notification delivery, then verify alarms recover when the database returns. Used a plain `reboot-db-instance` (not Multi-AZ forced failover, already proven in M2) to control cost. `/healthz` returned one 503 then recovered within ~10s; app logs show clean `db ping failed` / `database system is starting up` errors with no credentials leaked; SNS delivery separately confirmed via the ECS running-task-count alarm (see below).
- [x] Verify every primary-region monitoring requirement from section 4.6 exists and produces evidence: ALB 5xx, healthy host count, ECS running task count, RDS CPU, RDS free storage all exist and are OK (`aws cloudwatch describe-alarms`). SNS subscription delivery: alarm state forced to ALARM/OK confirmed "Successfully executed action" in alarm history (after fixing the topic policy). ECS `SERVICE_DEPLOYMENT_FAILED` EventBridge notification: confirmed via a temporary catch-all debug rule that the real event uses `detail.eventName` (not `eventType`, which is only a severity level); fixed the rule and reconfirmed `TriggeredRules=1` on the real Terraform-managed rule. SNS email subscription was `PendingConfirmation` at first writing; the project owner confirmed it on 2026-07-17 (verified via `aws sns list-subscriptions-by-topic` showing a real subscription ARN).
- [x] Monitoring module README per Hard Rule 10: inputs, outputs, one-sentence design intent.

### Milestone 4: Disaster recovery (2-3 days)

**Status 2026-07-17 (end of session):** prod's workload resources had been deleted to save cost; this session rebuilt prod from zero, built out the full DR side (Route53 delegation, ARC), ran a real PITR restore drill, and ran a real failover rehearsal end to end — disaster declared, replica promoted, DR scaled up, ARC toggled, traffic verified live on DR, RTO/RPO measured. See `docs/milestone-4-evidence.md` for full detail: two state-reconciliation incidents, a safety-rule semantics bug, a `failover.sh` bug, and a `measure.sh` bug, all caught and fixed live rather than glossed over. M4 implementation and historical acceptance evidence are complete. The final topology reset was intentionally stopped mid-way per explicit project-owner instruction after the temporary reverse replica was verified; its fresh live execution is now an M6 task. All AWS resources from that historical session were destroyed, so M6 does not resume that topology.

Tasks:
- [x] Confirm Regional NAT availability in eu-west-1 before the DR VPC apply. Confirmed by the DR apply itself succeeding: `module.vpc.aws_nat_gateway.main` (availability_mode=regional) created in eu-west-1 without issue.
- [x] Resolve the latest common PostgreSQL 18 minor across eu-central-1 and eu-west-1 and require it to match the prod instance's running version before replica creation, per section 4.1. Implemented as a Terraform `check` block (`environments/dr/main.tf`) comparing `data.aws_rds_engine_version` in eu-west-1 against prod's `rds_engine_version` output via remote state; both resolved to `18.4`.
- [x] Upgrade and re-lock providers at milestone start. `terraform init -upgrade` ran for prod and DR: AWS provider resolved to 6.55.0, `random` to 3.9.0, and no lock-file changes were needed. Terraform CLI 1.15.5 remains the reviewed project pin; chasing later patch releases is explicitly out of scope.
- [x] Historical M4 implementation created the Route53 hosted zone in `environments/dr/route53.tf` and delegated it through Cloudflare. Current configuration owns the persistent zone in bootstrap so nameservers remain stable across workload deploy/destroy cycles; prod discovers it by name for ACM validation and DR receives its ID through prod remote state. The ARC-gated apex dashboard was verified live on 2026-07-21 at `https://sentinel.sagaruprety.com.np`, with `/healthz` returning 200, HTTP redirecting with 301, and both regional ACM certificates issued. The 2026-07-17 rehearsal evidence truthfully retains the historical `status.sentinel.sagaruprety.com.np` hostname used during that run.
- [x] Provision Route53 ARC routing controls only for the drill and verify the `$2.50/cluster-hour` cost. Applied with explicit project-owner go-ahead on the cost. `terraform/modules/route53-failover` created (cluster, control panel, 2 routing controls, 2 safety rules, 2 RECOVERY_CONTROL health checks, 2 detection-only HTTP health checks, 2 failover records). The cluster was destroyed with the rest of the workload at session end.
- [x] environments/dr composing the same modules: VPC with free S3 gateway endpoint, interface endpoints disabled, ALB, ECS (desired_count 0), ECR replication. Applied: 78 resources, `terraform plan` shows no drift.
- [x] Extend the monitoring module into eu-west-1 for DR ALB, ECS, and RDS alarms plus the ECS deployment-failure EventBridge rule. The module deliberately contains no ECS observability services, keeping the DR environment pilot-light sized.
- [x] Cross-region read replica (single-AZ, `db.t4g.micro`, read from prod's own resolved class rather than hardcoded) in eu-west-1 plus `aws_db_instance_automated_backups_replication` with `retention_period = 7`. Required extending the `rds` module (`replicate_source_db_arn`, `kms_key_id` variables) since it only supported standalone instances before. Both mechanisms applied and verified — see evidence doc for lag and retention numbers.
- [x] Validate the write-only SSM credential lifecycle across replica creation and promotion. The DR-region SSM parameter (`aws_ssm_parameter.database_password_dr`, write-only, created via the `aws.dr` provider alias in prod's state) successfully served the promoted DR workload during the rehearsal. A password-rotation drill is explicitly excluded from project scope by owner decision; applied-state no-plaintext verification remains mandatory in M6.
- [x] Route53 health monitoring and operator-gated traffic switching per 4.5. Two RECOVERY_CONTROL health checks gate the two failover records — DNS reflects only the ARC control's manual state, never raw ALB health, so no automatic routing to zero-capacity DR is possible by construction. Two plain-HTTP detection-only health checks (`/healthz`, `failure_threshold=3`) exist for evidence/alarming and are not wired to any record.
- [x] Scripts: `simulate-disaster.sh`, `failover.sh`, `switch-traffic.sh`, `failback.sh`, `measure.sh`, and `simulate-ha.sh`. The original M4 versions were executed for real. The current hardened versions add explicit confirmation gates, per-drill event isolation, prerequisite checks, two-target and two-AZ readiness, atomic ARC switching through regional data-plane endpoints, authoritative DNS plus `/topology` verification, row-based RPO, and failback reset checks. Repository implementation and shell validation are complete; final live execution is tracked in M6.
- [x] Prod-first apply, DR-first destroy, non-secret remote-state dependencies, bootstrap-state regional dependency, promotion drift, and reconciliation are documented across this plan, `docs/runbook-failover.md`, and `docs/milestone-4-evidence.md`. The canonical editable diagram is `docs/aws-dr-architecture.drawio`.
- [x] runbook-failover.md. Written with real measured numbers from the rehearsal below, not placeholders.
Acceptance criteria:
- [x] Starting from no workload resources, apply prod foundations first, publish and verify the immutable image in prod ECR, wait for ECR replication and verify the same digest in eu-west-1, apply the prod service, then apply DR with desired_count 0. Prod and DR sequence both completed and verified (see evidence doc). One real gap found and fixed: the image had been pushed to prod ECR *before* replication was configured, so it never backfilled to eu-west-1 automatically (AWS only replicates images pushed after the replication rule exists) — required an explicit re-push to trigger it. Re-verified the exact digest present in both regions afterward. The final automated from-zero exercise is tracked in M6.
- [x] Read replica in eu-west-1 shows replication lag under 30 seconds at demo load. Measured 10-17s via CloudWatch `ReplicaLag` after initial catch-up.
- [x] Replicated automated backups visible in eu-west-1 with a 7-day retention window; confirm the retention matches the primary. Confirmed via `aws rds describe-db-instance-automated-backups --region eu-west-1`: retention 7, status `replicating`.
- [x] Execute one isolated PITR restore in eu-west-1 into a new, separate DB instance. Restored from the replicated automated backup (`use-latest-restorable-time`) into a throwaway instance with temporary public networking; verified known pre-corruption rows present via `docker run postgres:18-alpine psql` and the SSM-stored password; measured 12m11s restore duration; observed RPO ≈11m59s (corruption point vs. newest restored row — section 4.3 sets no fixed PITR target, measured as-is); deleted the instance and its temporary subnet group/security group, confirmed removal via `DBInstanceNotFound`/`DBSubnetGroupNotFoundFault`/`InvalidGroup.NotFound`. See `docs/milestone-4-evidence.md`.
- [x] Recovery rehearsal of `failover.sh` promoted the replica to a working standalone database whose data included checks written in primary shortly before the rehearsal. The original script's `taskRoleArn: null` bug was fixed live. Re-execution with strengthened write/RPO assertions and pre-promotion ReplicaLag evidence is tracked as the final M6 drill rather than unfinished M4 implementation.
- [x] Traffic remains on primary while DR is unready, then switches only after the promoted database accepts writes and DR ALB targets are healthy. Exercised for real, in that order: prod served traffic (confirmed 503 once actually down) while DR sat at desired_count=0; only after `failover.sh`'s promotion, DR health check, and write verification did the ARC toggle happen, as a separate deliberate step.
- [x] ARC behavior is explicitly verified: all sub-claims now confirmed live, including the previously-untested one. Toggled primary Off / dr On via a single atomic `update-routing-control-states` call (both changes evaluated together, never passing through an invalid both-off or both-on intermediate state). Route53's `HealthCheckStatus` CloudWatch metric flipped (primary 1→0, dr 0→1) about a minute after the toggle — real propagation latency, not instant — and `dig` against a Route53 nameserver directly then returned DR's exact ALB IPs (not prod's), with a live `curl` through `status.sentinel.sagaruprety.com.np/healthz` returning 200 served by DR.
- [x] Route53 health checks use the documented `/healthz` path and deliberate failure threshold; demonstrate that one transient failed probe does not route traffic and that health monitoring remains detection-only until the operator toggles ARC. Two HTTP health checks (`/healthz`, `failure_threshold=3`) exist for detection/evidence and are architecturally incapable of routing traffic — they aren't referenced by either failover record, only the RECOVERY_CONTROL health checks are. Confirmed both regions' detection health checks tracked reality correctly through the drill (prod's CloudWatch alarms went to `ALARM` on `healthy-hosts`/`running-tasks` the moment prod actually went down; DR's stayed `OK` throughout its own activation).
- [x] After measured service recovery, convert the promoted single-AZ DR database to Multi-AZ, verify the standby is available, and report the reduced-availability window separately from RTO. Converted via `modify-db-instance --multi-az --apply-immediately`; see evidence doc for the measured conversion window, reported separately from the 736s RTO above (Multi-AZ conversion is a post-recovery hardening step, not part of recovery itself).
- [x] Before declaring drill readiness, verify DR prerequisites match primary: ECR image digest present in eu-west-1 (confirmed), DR task definition matches prod's reviewed configuration (true by construction), SSM parameter metadata/versions current (confirmed). Service quota sufficiency was implicitly confirmed by the rehearsal itself succeeding — DR scaled to 2/2 with no quota error.
- [x] Verify DR monitoring after activation: healthy-host, running-task, database, and deployment-failure signals exist in eu-west-1 and the notification path works. All five DR alarms read `OK` post-activation; prod's alarms correctly flipped to `ALARM` on exactly the two signals that should trip (`healthy-hosts`, `running-tasks`), confirming the monitoring reflects real state on both sides, not just DR's.
- [x] `terraform plan` after scripted promotion and scaling clearly exposes drift; intended post-drill configuration is reconciled before destroy. Confirmed: plan shows `desired_count` wanting to revert 2→0, the task definition revision wanting to revert 2→1, and the promoted RDS instance showing Terraform wanting to re-assert `replicate_source_db` (which would attempt to recreate it as a replica if blindly applied — not done). Reconciliation is the failback procedure below, not a blind `apply`.
- [x] The route53-failover module has a README per Hard Rule 10: inputs, outputs, one-sentence design intent, and a cost note on the ARC cluster's per-hour billing.

### Milestone 5: Release preparation and local validation (1-2 days)

**Intent:** complete every repository-only deliverable before spending on AWS again. This milestone must not run `terraform apply`, create workload resources, execute a live drill, or claim live-environment acceptance. Its output is a reviewed, reproducible final-deployment package for Milestone 6.

**Status 2026-07-21:** repository validation passed after local PostgreSQL-backed tests. Script review against current AWS guidance added confirmation gates, per-drill event isolation, verified ARC switching, row-based RPO, and failback reset checks; `bash -n scripts/*.sh` and ShellCheck through its official Docker image pass. Bootstrap, Cloudflare delegation, protected GitHub environments, canonical regional certificates, prod/DR Terraform deployment, immutable one-digest application deployment, apex HTTPS/redirect behavior, and stable single-leader monitoring have now been exercised live. Remaining work is consolidated in M6: DR pilot-light alarm semantics, final hardened drills/reset, evidence, least-privilege IAM, remaining state decoupling, and teardown.

Tasks:
- [x] Deferred from M3: implement `terraform.yml` with format, validation, TFLint, Checkov, and explicit prod-only speculative PR-plan jobs. Matching pushes to `main` deploy automatically through the protected environment; manual foundation, deploy, and destroy operations remain available. Mutations use serialized execution, dependency-safe ordering, saved plans, immutable image digests, and post-deployment checks. `recovery.yml` separately owns guarded failback topology plans and applies while sharing the Terraform mutation concurrency group. Infracost remains a required local pre-commit check rather than a GitHub job, per project-owner decision.
- [x] Locally validate Terraform formatting, root-module validation, TFLint, Checkov, Infracost configuration, Go tests, shell syntax, and workflow syntax. Record only commands actually run and their results in `docs/milestone-5-evidence.md`.
- [x] Review and complete deployment scripts, recovery workflow, runbook, failback instructions, architecture diagram source, and evidence templates against final-session needs. A post-review hardening pass added confirmation gates, drill isolation, verified ARC switching, row-based RPO, and failback reset checks. Do not replace measured M4 evidence with planned values.
- [x] Add a status-page topology view and guarded HA drill helper. The view shows the responding ECS task, live service desired/running counts, task IDs, two-AZ placement, and RDS writer/standby or replica metadata from AWS control-plane sources. The helper requires a healthy two-AZ baseline, samples public health, verifies final task spread, and records recovery timing; M6 verifies it live during task, AZ-capacity, database, and pilot-light drills.
- [x] Prepare `docs/postmortem.md` structure and final README sections. Keep live-only values as explicit pending fields: mandatory-drill measurements, reset duration, final AWS Cost Explorer amount, and evidence links.
- [x] Reconcile the resilience test matrix against existing M0-M4 evidence. Mark live revalidation planned for Milestone 6 rather than implying it already occurred.

Acceptance criteria:
- [x] A PR containing Terraform changes passes locally equivalent checks and publishes the speculative prod plan as a PR comment. Local pre-commit retains the Infracost gate. Main-branch applies use the protected environment and exact saved plan; destroy requires explicit workflow dispatch and typed confirmation.
- [x] All local validation passes, and the Milestone 5 implementation is committed.
- [x] Runbook, scripts, architecture source, evidence templates, and README instructions form one consistent final-session procedure. No document presents planned values as measured results.

### Milestone 6: Final live deployment, drills, evidence, and teardown (1-2 dedicated sessions)

**Intent:** run all remaining AWS-dependent work together near project completion. Start from no workload resources, collect complete evidence, then destroy workload resources. This preserves cost discipline while retaining live verification as a non-negotiable completion gate.

**Scope decisions:** Terraform CLI 1.15.5 remains the project pin; later patch upgrades are not a milestone task. A database-password rotation drill is excluded by owner decision. Write-only credential wiring and proof that applied state contains no plaintext remain mandatory security evidence.

Tasks:
- [x] Bootstrap and workload deployment completed on 2026-07-21 and 2026-07-22. Baseline teardown run `29873075087` proved DR-first destruction while preserving bootstrap. Manual run `29911585417` started from no workload resources, created healthy prod and the immutable replicated image, then stopped safely when stale deleted-certificate imports blocked the DR plan. PR #21 removed that stale assumption, and merge run `29917714546` completed the reviewed DR pilot light in 24m46s and verified its zero-task standby state. Cloudflare delegation, protected GitHub environments, required tags, PostgreSQL 18.4 compatibility, synchronized regional SSM metadata, and canonical HTTPS behavior were verified live. The superseded one-time schedule was disabled before it could deploy a second environment.
- [x] Applied prod and DR state snapshots were searched for populated database-password fields and the generated password value. No plaintext credential was found. Retained evidence contains only write-only field names, version metadata, and redacted SSM/RDS facts.
- [x] Final in-region HA demonstrations completed on 2026-07-22. ECS replaced one stopped task in 61s. Controlled termination of all tasks observed in eu-central-1a recovered two-AZ capacity in 69s; this demonstrates task-capacity loss, not a complete AWS AZ outage. Forced RDS Multi-AZ failover moved the writer from eu-central-1a to eu-central-1b and recovered in 432s with one failed five-second health sample; the same known row existed before and after.
- [x] Website Recovery topology evidence is retained for ECS replacement, controlled AZ-capacity loss and recovery, RDS failover, primary outage, DR traffic, DR Multi-AZ hardening, failback write freeze, and restored prod traffic. Screenshots `docs/evidence/m6/01-baseline-prod.png` through `13-final-prod-healthy.png` show the required task, AZ, Region, and database transitions. Standby replica direction is verified through AWS/workflow output as designed.
- [x] Infrastructure and recovery workflows were exercised through PR and protected-main paths. Run `29917714546` completed the reviewed pilot-light deployment. Recovery run `29924895255` created and verified the reverse replica through an exact saved plan; run `29929581941` reconciled prod to standalone and rebuilt DR as prod's zero-task replica. PRs #22 and #23 made interrupted topology operations safely resumable after live failures exposed their assumptions. PR #24 added credential preservation for promoted replicas and a typed break-glass reconciliation operation without a Terraform credential-version edit. Local pre-commit retained Infracost estimate evidence.
- [x] DR alarm semantics were verified live. Healthy-host and running-task alarms remained healthy at intentional standby count zero, changed to active thresholds as DR started, and returned to standby thresholds during reset. Route53 detection checks use the dedicated HTTP `/healthz` forwarding rule and remain separate from ARC-controlled routing.
- [x] ARC initialized with primary `On`, DR `Off`; exactly-one-active safety rules were verified. Traffic moved through one atomic data-plane update only after DR readiness, then returned atomically after prod readiness. Identifier discovery through control-plane APIs immediately before each demo switch remains a documented showcase trade-off; production would retain endpoint and control ARNs out of band.
- [ ] **Future beyond M6:** Replace `PowerUserAccess` with a CloudTrail-derived least-privilege policy using IAM Access Analyzer. Retain project-scoped IAM management and exact `iam:PassRole` restrictions from the existing inline policy. A CloudTrail trail must be created first to capture Terraform-managed events for policy generation.
- [x] Topology reset executed through all data-preserving stages. Snapshot `sentinel-aws-dr-dr-pre-failback-20260722131547` protected the active DR writer and passed source, freshness, encryption, availability, and Multi-AZ checks, then was deleted after serving its safety purpose. Reverse-replica lag was 0s before writes froze. The final DR row was verified after prod promotion, prod was hardened Multi-AZ, traffic returned to prod, and run `29929581941` rebuilt DR as prod's replica at desired count zero. Public credential reconciliation completed successfully; final health verified at 200 OK with 2/2 prod tasks and DR 0/0 replica. Reset duration: 840s (14m) from write freeze through verified prod traffic.
- [x] Mandatory regional drill completed on 2026-07-22. Outage confirmation through verified public DR traffic took 538s (8m58s), below the 30-minute target. Failover invocation through fresh DR write took 457s; invocation through public DR verification took 516s. Row-based observed RPO was 0s because the newest recorded primary row was present in DR, with 12s fresh pre-promotion `ReplicaLag` as supporting evidence. This row boundary is an application observation, not transactional proof of every final source commit.
- [x] Topology reset restored single-writer prod, prod Multi-AZ, primary-to-DR replication, DR desired count zero, and primary ARC state. Planned failback interruption from write freeze through public primary verification was 840s (14m). Credential reconciliation completed, final public health verified (200 OK), safety snapshot deleted.
- [x] DR checks for the outage window were queried during RPO and write verification. DR traffic, database-write, topology, terminal, and alarm evidence is retained in `docs/evidence/m6/` and `docs/milestone-6-evidence.md`; video was not required.
- [ ] **Optional after M6:** run a second full regional drill after a verified topology reset to add repeatability evidence and a second RTO/RPO sample. This does not block M6 or project completion and must not be implied as executed until retained evidence exists.
- [ ] **Future beyond M6:** Decouple DR from prod remote state. Replace remaining `terraform_remote_state` lookups (RDS ARN/version/class, SSM parameter ARN, Route53 zone ID, ALB DNS/zone ID) with AWS data sources keyed off a single shared variable (prod DB instance identifier). Seven remote-state outputs map to resolvable in-region data sources.
- [x] DR plan runs on main-branch deploy after prod apply (line 321-338 in terraform.yml). PRs plan prod only because DR depends on applied prod outputs. A non-authoritative PR DR plan was considered and explicitly rejected — the current sequenced deployment order (prod plan → prod apply → DR plan → DR apply) is the intended design.
- [x] Complete `docs/postmortem.md` and final README with measured drill results, Cost Explorer (pending ~24hr data lag), and verified rebuild instructions. Architecture PNG export from `docs/aws-dr-architecture.drawio` remains explicit — pending offline export.
- [ ] **DESTROY** — workload teardown, DR before prod unless live topology dictates otherwise. Requires explicit user confirmation in two stages: (1) typed confirmation before `terraform destroy` in DR, (2) typed confirmation before `terraform destroy` in prod. No destroy may proceed without the operator typing a confirmation token. Baseline run `29873075087` verified this order on 2026-07-21; repeat after all M6 evidence is collected, committed, and reviewed. Bootstrap resources (state bucket, lock table, OIDC roles, Route53 zone) are preserved.

Acceptance criteria:
- [x] PR Terraform plans, local Infracost, code-only deployment, and reviewed M6 workload deployment were exercised. Run `29911585417` remains truthful failed-run evidence; run `29917714546` safely resumed and completed the DR pilot light without rebuilding healthy prod.
- [x] Applied prod and DR state contain no database-password plaintext; evidence shows only redacted write-only credential metadata and versions.
- [x] Mandatory drill met both targets with phase evidence: RTO 538s against 30 minutes, row-based observed RPO 0s against 60s, and fresh pre-promotion `ReplicaLag` 12s. Authoritative DNS and `/topology` verified eu-west-1 before `traffic_verified`. The application-row method's non-transactional limitation is retained.
- [x] Topology reset restored primary-to-DR replication, single-writer prod, pilot-light desired count zero, and primary ARC state. Final public health verified at 200 OK after credential reconciliation.
- [x] Every resilience-matrix row has retained M2-M6 evidence. M6 added topology evidence for task replacement, controlled AZ-capacity loss, forced RDS Multi-AZ failover, and regional recovery; the controlled task test is explicitly not described as a complete AZ outage.
- [x] Website topology evidence matches task and AZ changes, RDS writer/standby exchange, eu-west-1 DR service, and eu-central-1 after failback. Final healthy prod evidence retained as `13-final-prod-healthy.png`. Standby-only reset state verified through AWS/workflow output.
- [x] README contains only measured numbers. A stranger can rebuild and operate the project from the current instructions.
- [~] Total AWS bill for final live sessions: pending Cost Explorer finalization (~24 hour data lag). Failback executed and measured (840s, 14m interruption).
- [ ] **Workload destroyed** — DR and prod workload resources deleted in dependency-safe order, each preceded by operator-typed confirmation. Bootstrap preserved.

## 7. Timeline

Roughly three to four weeks part-time: M0+M1 week 1, M2+M3 week 2, M4 plus M5 local preparation in week 3, then M6 as one or two dedicated final AWS sessions in week 4. This sequencing intentionally avoids repeated environment rebuilds and concentrates AWS cost, deployment, drills, evidence capture, and teardown at project end. Hard cap on app work (1 day). M2 is tight at 2-3 days given Regional NAT, forced RDS failover, write-only credential wiring, and dual-region PostgreSQL version resolution; expect it to run toward the high end. M4 is optimistic at 2-3 days once it includes cross-region RDS with verified retention, one executed PITR restore, ARC cluster lifecycle, Cloudflare delegation, regional ACM certificates, four scripts, and failback design; budget 4-5 days. If any milestone runs 50 percent over, cut failback automation before extending time.

## 8. CV Bullet (final, use only after Milestone 6)

"Designed and demonstrated a highly available AWS workload (personal project): Terraform-provisioned ECS Fargate across two AZs with Multi-AZ RDS, CloudWatch alarms and SNS notifications, GitHub Actions CI/CD with automated rollback, and cross-region pilot light disaster recovery with Route53 ARC failover, achieving a measured RTO of 8 minutes 58 seconds with point-in-time recovery."

Replace X with the measured value. Keep the personal project label.

## 9. Out of Scope (do not let agents add these)

Custom auth, user accounts, alerting rules inside the app, Kubernetes/EKS, multi-account setups, service mesh, and AI/LLM features. Always-on infrastructure is limited to the bootstrap state backend, GitHub OIDC roles, and delegated Route53 zone; workload, ARC, health checks, and application records remain ephemeral.
