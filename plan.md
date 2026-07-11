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
4. Cost discipline: nothing in this project runs 24/7 except the bootstrap state bucket. Every milestone ends with `terraform destroy` verified clean (zero orphaned resources, checked via AWS CLI). NAT gateway and interface endpoint usage are minimized. Before each apply, review an Infracost estimate and use an AWS Budget alert. Provisional ceiling for one complete build and drill session: 10 EUR until measured. The final README reports the actual AWS Cost Explorer amount and session duration, never an estimate presented as fact.
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
  - Explicitly forbidden: React or any framework, Tailwind or any CSS build, npm or any build step, more than the one CDN chart library above, theme toggles, animations beyond the refresh. Rich time-series visualization belongs in Grafana (section 4.5), not in the app.

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

Observability in the app: expose `GET /metrics` in Prometheus format (check counts, check latency histogram, up/down gauge per target) using the OpenTelemetry SDK with a Prometheus exporter. Structured JSON logs to stdout. Public metrics exposure is accepted only for the ephemeral demo and must contain no secrets or unbounded labels. Restrict `/metrics` to the demo operator's source CIDR with an ALB source-IP listener rule. WAF is out of scope. Document that a production deployment would expose metrics only on a private listener.

## 4. Architecture Specification

Version policy:
- Use Terraform 1.15.5 from `.terraform-version`; every root module declares `required_version = ">= 1.11, < 2.0"` because write-only arguments require Terraform 1.11 or newer.
- Use the latest stable AWS provider major 6 release available when a milestone starts, constrained as `~> 6.0`, and the latest compatible HashiCorp Random provider for ephemeral password generation. Run `terraform init -upgrade`, review provider changelogs and the plan, and commit lock files for bootstrap, prod, and DR. "Latest" means intentionally upgraded and locked, not an unbounded provider constraint.
- Pin PostgreSQL major 18 while resolving its latest common regional minor as described below. Major upgrades require a separate reviewed change and test; latest does not mean automatic major-version drift.

### 4.1 Primary region (eu-central-1)
- VPC `10.0.0.0/24` across eu-central-1a and eu-central-1b. Allocate two public `/27` subnets for ALB and NAT, two private application `/27` subnets for ECS, and two isolated database `/28` subnets for RDS. A `/27` has 27 AWS-usable addresses and a `/28` has 11, enough for two steady ECS tasks, deployment overlap, ALB nodes, one NAT ENI, and RDS failover with substantial headroom. Reserve the remaining addresses for growth. The DR VPC uses non-overlapping `10.1.0.0/24`; document the address calculation in the module README.
- ALB in public subnets, HTTP :80 only. `sagaruprety.com.np` remains authoritative in Cloudflare. Delegate the `sentinel.sagaruprety.com.np` subdomain to a Route53 public hosted zone using NS records in Cloudflare. Publish the workload at `status.sentinel.sagaruprety.com.np`; Route53 manages only records below the delegated `sentinel` zone and the operator-gated regional route. Direct ALB testing does not require DNS. HTTPS and ACM remain optional enhancements and must not block recovery work.
- ECS Fargate cluster. One service, desired_count = 2 in demo mode, 1 in idle-testing mode. Tasks in private subnets. CPU 256, memory 512.
- Pin an explicit supported Fargate Linux platform version in Terraform and record it in the module README; do not rely silently on a changing `LATEST` value.
- Egress for image pull, logs, SSM retrieval, and external checks uses one NAT gateway in one public subnet plus the free S3 gateway endpoint. NAT is part of every applied prod and DR environment, not a feature flag, because the workload cannot perform its core checks or reliably start replacement tasks without it. Document the deliberate single-NAT AZ dependency: existing healthy tasks can keep serving during NAT failure, but external checks and replacement-task startup may fail. A production design would use one NAT per AZ or selected interface endpoints according to measured availability and traffic.
- RDS PostgreSQL: pin major version 18 and use `data.aws_rds_engine_version` with `version = "18"` and `latest = true` to select the latest minor available in both eu-central-1 and eu-west-1 at apply time. Record the resolved minor in evidence and require both regions to match before replica creation. Enable automatic minor upgrades; never float automatically to a new major. Use db.t4g.micro if orderable for the resolved version in both regions, otherwise select the smallest supported Graviton class and document the cost change. Configure 20 GB gp3, backup_retention_period = 7, storage encryption, deletion_protection = false, and skip_final_snapshot = true. Module README must warn that the deletion settings are demo-only and that burstable instances can lag under sustained load. `multi_az` is true for the Milestone 2 HA test and full demo, false only for explicitly labeled basic testing.
- Multi-AZ RDS synchronously maintains a standby in another AZ for availability; that standby is not a backup. RDS automated backups provide the seven-day regional PITR window and are stored by the managed service independently of one DB AZ. Cross-region automated backup replication separately copies recovery data to eu-west-1 for regional disaster and corruption recovery. No manual or final snapshot is retained after teardown unless a drill explicitly creates one and deletes it after evidence collection.
- Security groups chained: ALB (ingress 80 from 0.0.0.0/0) -> ECS tasks (ingress 8080 from ALB SG only) -> RDS (ingress 5432 from ECS SG only).
- ECR repository with lifecycle policy (keep last 10 images).
- State-safe SSM credentials: Terraform 1.11+ creates one ephemeral random password during the prod apply. The same ephemeral value flows to RDS through `password_wo` and to Standard-tier SecureString parameters in eu-central-1 and eu-west-1 through `value_wo`, using aliased AWS providers. Keep `password_wo_version` and both `value_wo_version` values synchronized through one explicit credential version variable. The plaintext never enters Terraform state. The prod stack owns both regional parameter metadata so the DR parameter exists before failover and the promoted replica uses the inherited password. ECS task execution roles receive narrowly scoped `ssm:GetParameters` and `kms:Decrypt` permissions for only their regional parameter and key.

### 4.2 DR region (eu-west-1), pilot light
- Mirrored VPC `10.1.0.0/24` with the same `/27` public, `/27` application, and `/28` database subnet pattern, one NAT gateway, free S3 gateway endpoint, ALB, ECS cluster, task definition, and service with desired_count = 0. Paid interface endpoints remain optional and disabled by default. Terraform composes the same modules with different variables. The recovery environment cannot process requests until the database is promoted and compute is started, so this is pilot light rather than warm standby. Live replicated data and core network resources remain available while application compute is switched off, matching the AWS pilot-light guidance.
- Database, two complementary mechanisms (state the rationale for both in the README):
  1. Cross-region read replica: a single-AZ db.t4g.micro read replica in eu-west-1 created from the primary (streaming replication, RPO of seconds under demo load). On failover it is promoted to standalone primary, which takes minutes. This keeps the data resource always on in the recovery region, matching the whitepaper pilot light definition, and is the fast RTO path. It runs only during demo sessions (the whole environment is ephemeral).
  2. RDS Cross-Region Automated Backup Replication (Terraform resource `aws_db_instance_automated_backups_replication`, snapshots plus transaction logs, point-in-time restore in eu-west-1). This is the corruption protection layer: a replica faithfully replicates corrupted or deleted data, so PITR backups are what allow rewinding to the last good state, per the whitepaper caveat. Cost is cents.
- The DR network and ALB span two AZs. When recovery starts, ECS scales to two tasks distributed across those AZs. The always-on read replica is intentionally single-AZ to control pilot-light cost; immediately after service recovery, convert the promoted DR database to Multi-AZ as a separate stabilization step and measure that duration. State clearly that the recovered service has reduced database availability between promotion and completion of this conversion.
- The failover script uses replica promotion as the primary recovery path; the runbook documents PITR restore as the corruption-scenario alternative, including its expected 15-60 minute restore duration.
- ECR replication rule so the image exists in eu-west-1.

Apply prod before DR because the replica, backup replication, and ECR replication depend on primary resource identifiers. Keep environment state separate and pass only documented non-secret outputs through `terraform_remote_state`. Store state in the bootstrap bucket and document that a primary-region S3 outage can prevent Terraform-driven recovery; the failover runbook must remain executable with AWS CLI using recorded resource identifiers. Destroy DR before prod. Promotion changes replica topology and CLI scaling changes ECS desired count, so the runbook must reconcile configuration and Terraform state after every drill.

### 4.3 Failover automation

Recovery objectives, defined before testing:
- Replica-promotion path target RTO: 30 minutes from operator invocation until verified DR service.
- Replica-promotion path target RPO: 60 seconds at demo load, measured from the newest primary check visible in DR after promotion.
- PITR corruption path target RPO: no more than the service-supported restore granularity; measure it during the drill rather than assuming a value.

Automation is operator-initiated and then runs end to end. DNS must never route users to an unready pilot light:
- `scripts/simulate-disaster.sh`: records the start timestamp and sets primary ECS desired_count to 0 to simulate regional application failure. It does not alter traffic routing.
- `scripts/failover.sh`: promotes the eu-west-1 read replica to standalone primary, waits for writability, registers a new DR task definition with the promoted endpoint and validated region-local secret ARN, scales DR ECS service to 2, verifies target health and application writes, then enables the DR traffic route as the final step.
- Traffic switching uses an operator-gated Route53 Application Recovery Controller routing control connected to the `status.sentinel.sagaruprety.com.np` records. Provision the ARC routing-control cluster only for the drill; its published rate was $2.50 per cluster-hour when this plan was revised, but verify current pricing before apply. Include the charge in session evidence and destroy the cluster immediately afterward. Fallback: a deliberate Route53 record update after readiness verification, clearly identified as a less resilient control-plane operation. Automatic primary-health-check DNS failover to an unready DR ALB is forbidden.
- `scripts/failback.sh`: documents and automates safe steps where practical. After DR accepts writes, the old primary cannot simply resume. Rebuild the original region from the DR primary, establish reverse replication, verify consistency, switch traffic only after readiness, and restore the intended replication topology. A destructive snapshot-based alternative must state its data-loss and RTO implications.
- `scripts/measure.sh`: timestamps detection, promotion, task startup, health verification, and traffic switch; prints measured RTO and derives RPO from the newest pre-disaster row present after promotion.
- Every script records changed resources. After the drill, update Terraform configuration to the intended topology and run `terraform plan` to inspect drift before apply or destroy. Never use `terraform apply -refresh-only` as a substitute for declaring the desired post-drill configuration.

### 4.4 Cost rationale for paid services

Every project service is chosen intentionally. Here is why each paid service is necessary and what would break without it.

**NAT Gateway:** ECS tasks in private subnets need internet egress to check external URLs and start reliably without paid interface endpoints. Without NAT, the app can still serve stored results but cannot perform its core checks. Putting tasks in public subnets with public IPs broadens exposure and is rejected. One NAT is therefore created by default in each applied environment, with no enable/disable variable. Exact regional hourly and data-processing charges come from Infracost and the final bill.

**ALB:** Required for load balancing across ECS tasks, HTTP health checks, and the Route53 target. Fargate tasks have dynamic IPs, so a stable endpoint is needed. A Network Load Balancer does not provide the required Layer 7 health and routing behavior. Use current regional Infracost data instead of hard-coded rates.

**ECS Fargate:** The compute platform for the container. The project's core premise is a containerized AWS workload with HA/DR. Lambda is unsuitable for the long-lived checking loop, while EC2 introduces OS maintenance and idle instance capacity. Use current regional Infracost data instead of hard-coded rates.

**RDS Multi-AZ:** Multi-AZ is enabled only during demo sessions to test within-region database failover. During basic testing, set `multi_az = false` to reduce cost. Do not assume Free Tier eligibility. Confirm instance availability and current regional rates through the AWS provider and Infracost before implementation.

**VPC endpoints:** The S3 gateway endpoint has no hourly charge and reduces NAT traffic, so it is enabled. ECR API/DKR, CloudWatch Logs, and SSM interface endpoints charge per endpoint per AZ plus data processing. For this ephemeral, low-traffic workload they are disabled by default because their fixed hourly cost is likely greater than NAT processing savings. They remain module options to demonstrate the production trade-off between private AWS API paths, NAT/AZ failure behavior, and cost.

**SSM Parameter Store:** Two regional Standard-tier SecureString parameters hold the same RDS password, one for prod ECS and one for DR ECS. Terraform ephemeral values plus AWS provider write-only arguments keep plaintext out of state. Standard parameters fit the small secret count and avoid Secrets Manager. KMS API charges, if any, are included in measured session cost.

### 4.5 Route53
- Keep health checks for detection and evidence, with a deliberate `failure_threshold` that avoids reacting to a single transient failure. Do not attach automatic failover routing that sends users to DR while its desired count is zero. Traffic changes only after `failover.sh` verifies the promoted database, healthy DR targets, and successful writes. Prefer an operator-gated Route53 ARC routing control because it uses a highly available data-plane API; if ARC is outside budget or prerequisites, use a scripted Route53 record update and document its control-plane dependency.
- The registered parent domain `sagaruprety.com.np` remains on Cloudflare. Terraform creates the `sentinel.sagaruprety.com.np` Route53 public hosted zone. Add its returned NS records to Cloudflare once, then verify delegation with `dig NS sentinel.sagaruprety.com.np`. Route53 owns `status.sentinel.sagaruprety.com.np` and its ARC routing controls without moving the parent domain away from Cloudflare.

### 4.6 Monitoring
- CloudWatch alarms: ALB 5xx count, ALB healthy host count < 1, ECS running task count < desired, RDS CPU > 80, RDS free storage low. All alarms notify one SNS topic with email subscription.
- EventBridge rule on ECS `SERVICE_DEPLOYMENT_FAILED` -> same SNS topic (circuit breaker visibility).
- OpenTelemetry/Prometheus: run Prometheus and Grafana locally via docker-compose during the demo, with the operator source CIDR allowed to scrape `/metrics`. Hosted Grafana on ECS is out of scope unless all required milestones are complete. Provision a screenshot-ready local dashboard and document the public-demo metrics trade-off.
- CloudWatch alarms are regional. Create and verify alarms in both regions and document that the local Grafana dashboard is the cross-region operator view for the demo; do not imply CloudWatch automatically aggregates regional alarms.

### 4.7 ECS deployment safety
- Deployment circuit breaker enabled with rollback = true.
- The pinned AWS provider (`~> 6.0`, see `terraform.tf`) exposes only `enable` and `rollback` in Terraform's `deployment_circuit_breaker` block as of this writing (tracked upstream: hashicorp/terraform-provider-aws#48748, still open). Do not use `local-exec` or out-of-band service mutations to force an unsupported threshold, because that creates unmanaged drift. Use the provider-supported default failure threshold, measure actual rollback duration, and report it honestly. Re-evaluate only after the pinned provider's resource schema natively supports configurable thresholds; check the provider CHANGELOG before assuming.

### 4.8 Resilience test matrix

No finite demo proves every possible failure. Test one representative recovery path at each layer and state untested risks explicitly:

| Layer | Injected failure | Expected recovery and evidence |
|---|---|---|
| Application process | Stop one ECS task | ALB removes target; ECS replaces task; no user-visible outage with second task healthy |
| Application release | Deploy image that exits | ECS circuit breaker rolls back; SNS notification arrives; measured rollback time |
| Application dependency | Make database unavailable during a controlled test | `/healthz` fails, ALB removes affected targets, structured logs identify DB dependency without leaking credentials |
| External egress | Remove the NAT route or otherwise block controlled egress | App still serves stored status; external checks turn red; replacement-task limitation is documented; restore route afterward |
| Availability Zone compute | Stop all ECS tasks placed in one AZ | Remaining-AZ task serves traffic; ECS restores desired count across available capacity |
| Availability Zone database | Force RDS Multi-AZ failover | App reconnects through unchanged RDS endpoint; measure application-visible interruption |
| Regional application and database | Stop primary ECS, promote DR replica, start DR ECS, then switch traffic | Pilot-light runbook meets measured RTO/RPO targets |
| Data corruption or deletion | Restore cross-region automated backup to a new isolated DB | Verify PITR data point without replacing healthy primary; measure restore and validation time if executed |
| Artifact/configuration drift | Verify image digest, task definition, SSM parameter metadata, service quotas, and Terraform plan in DR | Recovery prerequisites match primary before declaring drill readiness |
| DNS/control plane | Exercise ARC routing control and document fallback | Traffic changes only after DR readiness; no automatic route to zero-capacity DR |

Do not simulate an AWS regional outage by claiming that scaling ECS to zero is equivalent. Label it accurately as a controlled regional workload failure used to execute and measure the same recovery path.

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
│   │   ├── route53-failover/
│   │   └── ecr/
│   └── environments/
│       ├── bootstrap/        # state bucket + DynamoDB lock table
│       ├── prod/             # eu-central-1
│       └── dr/               # eu-west-1
├── scripts/
│   ├── simulate-disaster.sh
│   ├── failover.sh
│   ├── failback.sh
│   └── measure.sh
├── .github/workflows/
│   ├── app.yml               # build, test, push to ECR, deploy
│   └── terraform.yml         # fmt, validate, tflint, checkov, plan on PR, apply on main
├── observability/
│   └── docker-compose.yml    # local Prometheus + Grafana for demos
├── docs/
│   ├── architecture.md       # diagram, state dependencies, lifecycle, and decisions
│   ├── postmortem.md         # written after the first real drill
│   ├── runbook-failover.md
│   └── demo.gif / demo.mp4
└── README.md
```

## 6. Milestones

Each milestone has acceptance criteria. An agent must not mark a milestone complete until every criterion is verifiably met (command output or screenshot). Every milestone that creates AWS resources ends with a verified destroy unless stated otherwise.

### Milestone 0: Bootstrap and scaffolding (0.5 day)
Tasks:
- [x] Create repo with the layout above, root README stub, .gitignore (Terraform, Go), LICENSE (MIT).
- [~] `terraform/environments/bootstrap`: S3 bucket (versioned, encrypted) + DynamoDB table for state locking. Apply once, keep running (cost: cents). _(code written, needs AWS creds to apply)_
- [~] Configure S3 backend in prod and dr environments. _(backend.tf written, bucket placeholder needs update after bootstrap apply)_
- [x] Pre-commit hooks: terraform fmt, tflint.
Acceptance criteria:
- [ ] `terraform init` succeeds in prod and dr with remote state.
- [x] `git log` shows conventional, meaningful commits.

### Milestone 1: Application (1.5 days, hard cap; at most half a day of that on the UI)
Tasks:
- [x] Implement the app per section 3, including /metrics and the static page.
- [x] Unit tests for the check logic (mock HTTP) and one integration test with Postgres via testcontainers or docker-compose.
- [x] Dockerfile: multi-stage build, non-root, final image under 30 MB for Go. _(15.3 MB)_
- [x] docker-compose.yml for local dev (app + postgres).
Acceptance criteria:
- [x] `docker compose up` locally: /healthz 200, /status shows real check results within 60 seconds, / renders the status page per the UI spec (banner, cards, last-50-checks strips, auto-refresh), /metrics returns Prometheus text.
- [x] Visual check: the page looks like a credible modern status page in a screenshot, and a failed target visibly turns its card and strip red within one refresh cycle.
- [x] Tests pass in CI-runnable form (`go test ./...`).
- [x] Total app code stays under approx 400 lines excluding tests. If exceeding, simplify.

### Milestone 2: Core infrastructure, single region (2-3 days)
Tasks:
- [ ] Upgrade and lock Terraform providers: Terraform 1.15.5, `required_version >= 1.11, < 2.0`, latest reviewed AWS provider 6.x, and latest compatible Random provider. Commit regenerated lock files for all roots.
- [ ] Modules: vpc, alb, ecs-service, rds, ecr per section 4.1. Compose in environments/prod.
- [ ] Implement the `/24` VPC and calculated `/27` public/application plus `/28` database subnets in each AZ; add tests or assertions for non-overlap and expected usable capacity.
- [ ] Free S3 gateway endpoint; optional paid interface endpoints disabled by default; one NAT gateway created unconditionally in the applied environment with its AZ failure mode documented.
- [ ] Generate one ephemeral database password and write it through `password_wo` plus both regional SSM `value_wo` parameters; prove plaintext is absent from plan output and state.
- [ ] Resolve the latest common PostgreSQL 18 minor and compatible smallest Graviton class in both regions; record the selected versions.
- [ ] Push image to ECR manually for this milestone (CI comes in M3).
- [ ] ECS service with circuit breaker enabled per 4.6.
Acceptance criteria:
- [ ] `terraform apply` from zero completes in one run with no manual steps.
- [ ] App reachable via ALB DNS, /status shows checks flowing, self-check target (SELF_URL) green.
- [ ] Post-apply smoke test verifies `/healthz`, `/status`, and `/metrics` through the ALB; metrics expose no secrets and access matches the documented demo restriction.
- [ ] Kill one task manually (aws ecs stop-task): ALB marks target unhealthy, ECS replaces it, service recovers without intervention. Save the timeline as evidence for docs.
- [ ] RDS is Multi-AZ (verify via `aws rds describe-db-instances`), then force an RDS failover with `aws rds reboot-db-instance --force-failover`; measure application-visible downtime separately from ECS task replacement.
- [ ] Security group chain verified: direct requests to task IP and DB from the internet fail.
- [ ] IAM policies pass Checkov; every required `Resource = "*"` exception is action-scoped and documented.
- [ ] `terraform destroy` completes clean; `aws resourcegroupstaggingapi get-resources` filtered by project tag returns nothing in eu-central-1 (except bootstrap).
- [ ] Record apply-to-healthy wall time; it becomes the "environment rebuild time" claim in the README (this is itself the backup and restore DR baseline).
- [ ] Infracost estimate is reviewed before apply and actual session duration/cost evidence is retained.
- [ ] `terraform providers` and committed lock files show only reviewed current provider versions; no root remains locked to AWS provider 5.x.

### Milestone 3: CI/CD, monitoring, deployment safety (2 days)
Tasks:
- [ ] terraform.yml workflow: fmt-check, validate, tflint, checkov, Infracost diff, and plan on PR with useful output posted as a PR comment. Apply and destroy are separate `workflow_dispatch` jobs protected by GitHub environment approval; merging code must not create infrastructure automatically.
- [ ] app.yml workflow: test, build, push to ECR (OIDC federation for GitHub Actions role, no long-lived AWS keys), update ECS service.
- [ ] monitoring module: CloudWatch alarms + SNS + EventBridge rule per 4.5.
- [ ] observability/docker-compose.yml: Prometheus scraping the public /metrics, Grafana with one provisioned dashboard built to be screenshot-ready for the README and demo recording.
Acceptance criteria:
- [ ] A PR with a Terraform change shows plan and Infracost information as a comment; an approved manual workflow applies the reviewed commit.
- [ ] A code change deploys to ECS via pipeline with zero manual steps.
- [ ] Broken-image demo: push an image that exits on start; provider-supported circuit breaker defaults trip, rollback completes, SNS email arrives, service stays healthy on old version. Record actual rollback duration without claiming a custom threshold.
- [ ] Grafana dashboard shows live data during a demo session.

### Milestone 4: Disaster recovery (2-3 days)
Tasks:
- [ ] Create the Route53 hosted zone `sentinel.sagaruprety.com.np`, add its NS delegation records to the existing Cloudflare `sagaruprety.com.np` zone, verify delegation, and publish `status.sentinel.sagaruprety.com.np`.
- [ ] Provision Route53 ARC routing controls only for the drill, verify the `$2.50/cluster-hour` cost in Infracost or AWS pricing evidence, and destroy the ARC cluster immediately after recording.
- [ ] environments/dr composing the same modules: VPC with free S3 gateway endpoint, optional paid interface endpoints disabled, ALB, ECS (desired_count 0), ECR replication.
- [ ] Cross-region read replica (single-AZ db.t4g.micro) in eu-west-1 plus `aws_db_instance_automated_backups_replication` from prod RDS to eu-west-1 (both mechanisms per 4.2).
- [ ] Validate the write-only SSM credential lifecycle across replica creation, password rotation versioning, and promotion; prove the DR task retrieves its region-local parameter without exposing plaintext to Terraform state or logs.
- [ ] Route53 health monitoring and operator-gated traffic switching per 4.5. Never route automatically to zero-capacity DR.
- [ ] Scripts: simulate-disaster.sh, failover.sh (replica promotion path), failback.sh, measure.sh.
- [ ] `docs/architecture.md` documents prod-first apply, DR-first destroy, non-secret remote-state dependencies, bootstrap-state regional dependency, promotion and ECS drift, and reconciliation procedure.
- [ ] runbook-failover.md documents each step, target and measured duration, verification commands, post-promotion billing cleanup, safe failback/reverse-replication model, and PITR restore as the corruption-scenario alternative. Any restore duration remains an estimate until measured.
Acceptance criteria:
- [ ] Both environments apply cleanly from zero.
- [ ] Read replica in eu-west-1 shows replication lag under 30 seconds at demo load (`aws rds describe-db-instances` / ReplicaLag metric).
- [ ] Replicated automated backups visible in eu-west-1 (`aws rds describe-db-instance-automated-backups --region eu-west-1`).
- [ ] Dry run of failover.sh promotes the replica to a working standalone database whose data includes checks written in the primary shortly before the drill; calculate observed RPO against the 60-second target.
- [ ] Traffic remains on primary while DR is unready, then switches only after the promoted database accepts writes and DR ALB targets are healthy.
- [ ] After measured service recovery, convert the promoted single-AZ DR database to Multi-AZ, verify the standby is available, and report the reduced-availability window separately from RTO.
- [ ] `terraform plan` after scripted promotion and scaling clearly exposes drift; intended post-drill configuration is reconciled before destroy.
- [ ] DR is destroyed before prod, including the promoted standalone database, and zero billed recovery resources remain.

### Milestone 5: The drill, the evidence, the writeup (2 days)
Tasks:
- [ ] Full disaster drill end to end: traffic on primary -> simulate-disaster.sh -> detection -> operator invokes failover.sh -> replica promotion -> DR readiness verification -> traffic switch -> DR serving traffic. measure.sh captures phase timestamps. Run at least twice; report both runs against the predefined 30-minute RTO and 60-second RPO targets, not just the better run.
- [ ] Query the checks table in DR for the outage window; screenshot/export as evidence.
- [ ] Record terminal + Grafana + status page side by side; produce demo.gif (short) and demo.mp4 (full).
- [ ] docs/postmortem.md: separate timelines for ECS replacement, RDS Multi-AZ failover, deployment rollback, and regional DR; detection, impact, measured RTO/RPO against targets, and improvements such as warm standby trade-offs and automation gaps.
- [ ] Execute every practical row in the resilience test matrix. Mark destructive or cost-prohibitive rows not executed, explain why, and never imply that the matrix covers every possible failure.
- [ ] docs/architecture.md with diagram (mermaid in-repo plus one exported PNG).
- [ ] Final README: pitch, diagram, demo GIF at top, measured RTO/RPO, actual Cost Explorer session cost and duration, why infrastructure is ephemeral, and design decisions (single NAT, optional endpoints, desired_count 0 vs not-deployed, operator-gated traffic switch, provider-supported circuit breaker behavior, secret lifecycle, state dependency, and failback model), plus complete run instructions.
- [ ] Destroy both environments; verify zero remaining resources in both regions except bootstrap.
Acceptance criteria:
- [ ] README contains only measured numbers, no estimates presented as measurements.
- [ ] A stranger can rebuild the entire project from the README in one sitting.
- [ ] Total AWS bill for the whole build reviewed and stated in the README cost section.
- [ ] Failback is either executed and measured or explicitly documented as unexecuted; no claim implies it was tested when it was not.

## 7. Timeline

Roughly three weeks part-time: M0+M1 week 1, M2+M3 week 2, M4+M5 week 3. Hard cap on app work (1 day). If any milestone runs 50 percent over, cut optional scope (HTTPS, hosted Grafana on ECS, failback automation) before extending time.

## 8. CV Bullet (final, use only after Milestone 5)

"Designed and demonstrated a highly available AWS workload (personal project): Terraform-provisioned ECS Fargate across two AZs with Multi-AZ RDS, CloudWatch and OpenTelemetry monitoring, GitHub Actions CI/CD with automated rollback, and cross-region pilot light disaster recovery with Route53 failover, achieving a measured RTO of X minutes with point-in-time recovery."

Replace X with the measured value. Keep the personal project label.

## 9. Out of Scope (do not let agents add these)

Custom auth, user accounts, alerting rules inside the app, Kubernetes/EKS, multi-account setups, service mesh, HTTPS/ACM (optional stretch only), AI/LLM features, any always-on infrastructure beyond the bootstrap state bucket.
