# Project Plan: Resilient Status Page on AWS

Portfolio project for Sagar Koirala. Target roles: Senior DevOps Engineer / Platform Engineer (Germany).
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
4. Cost discipline: nothing in this project runs 24/7. Every milestone ends with `terraform destroy` verified clean (zero orphaned resources, checked via AWS CLI). NAT gateway usage is minimized (see 4.2). Target cost per full demo session: under 2 EUR.
5. Regions: primary eu-central-1 (Frankfurt), DR eu-west-1 (Ireland).
6. All infrastructure via Terraform. No console-created resources except the initial bootstrap (state bucket, see Milestone 0) if unavoidable, and even that should be scripted.
7. Least privilege IAM everywhere. No wildcard `*` actions on `*` resources in any role created for this project.
8. Secrets only in AWS Secrets Manager or SSM Parameter Store (SecureString). Never in Terraform state outputs, never in code, never in CI logs.
9. App stays trivial: one container, one main Postgres table, three or four endpoints, no auth, no user accounts, no alert-rule engine. If a change makes the app more interesting than the infrastructure, reject it.
10. Every Terraform module gets a README with inputs, outputs, and one sentence on design intent.

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
  - Hard cap: half a day of work. Explicitly forbidden: React or any framework, Tailwind or any CSS build, npm or any build step, more than the one CDN chart library above, theme toggles, animations beyond the refresh. Rich time-series visualization belongs in Grafana (section 4.5), not in the app.

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

Configuration via env vars only: DATABASE_URL (assembled from Secrets Manager values by the task definition), SELF_URL, CHECK_INTERVAL_SECONDS (default 30), PORT (default 8080).

Observability in the app: expose `GET /metrics` in Prometheus format (check counts, check latency histogram, up/down gauge per target) using the OpenTelemetry SDK with a Prometheus exporter. Structured JSON logs to stdout.

## 4. Architecture Specification

### 4.1 Primary region (eu-central-1)
- VPC 10.0.0.0/20 with /24 subnets, two AZs (eu-central-1a, eu-central-1b). Public subnet plus private subnet per AZ. Internet Gateway. CIDR is right-sized deliberately and must not overlap with the DR VPC (10.1.0.0/20) so cross-region peering or VPN remains possible; state this reasoning in the vpc module README.
- ALB in public subnets, HTTP :80 only (no custom domain or ACM cert required; Route53 failover works on ALB DNS via CNAME/alias on a health-checked record set, see 4.4). If a domain is available later, add HTTPS as an optional enhancement, do not block on it.
- ECS Fargate cluster. One service, desired_count = 2 in demo mode, 1 in idle-testing mode. Tasks in private subnets. CPU 256, memory 512.
- Egress for image pull and outbound checks: use VPC endpoints (ECR api + dkr, S3 gateway, CloudWatch Logs, SSM) to avoid a NAT gateway for AWS traffic. The app also needs general internet egress for its uptime checks, so one NAT gateway in one AZ is acceptable during demo sessions only. Document this trade-off in the module README, including the failure mode: if the NAT's AZ fails, the app keeps serving (AWS traffic uses endpoints) but external checks fail, so the status page would show external targets red.
- RDS PostgreSQL 16, db.t4g.micro, 20 GB gp3, backup_retention_period = 7, storage_encrypted = true, deletion_protection = false (ephemeral project), skip_final_snapshot = true. Module README must warn that skip_final_snapshot and deletion_protection = false are ephemeral-demo settings and must never be copied to production, and note that burstable instances with synchronous replication can lag under sustained load (acceptable at demo load). `multi_az` is a boolean variable: true during demo sessions (shows RDS cross-AZ failover), false during idle testing (saves cost). Default: false.
- Security groups chained: ALB (ingress 80 from 0.0.0.0/0) -> ECS tasks (ingress 8080 from ALB SG only) -> RDS (ingress 5432 from ECS SG only).
- ECR repository with lifecycle policy (keep last 10 images).
- SSM Parameter Store (SecureString) for DB credentials, generated by Terraform `random_password`, injected into task definition via `secrets` block. Chosen over Secrets Manager ($0.40/secret/month) because SSM is $0.05/parameter/month and this project has exactly one secret. Trade-off: no automatic rotation, but for an ephemeral demo project that is acceptable.

### 4.2 DR region (eu-west-1), pilot light
- Mirrored VPC (10.1.0.0/20, non-overlapping with prod), subnets, VPC endpoints (same set as prod: ECR api + dkr, S3 gateway, CloudWatch Logs, SSM), ALB, ECS cluster, task definition, and service with desired_count = 0. Terraform composes the same modules with different variables; the vpc module must include the endpoints so DR gets them automatically.
- Database, two complementary mechanisms (state the rationale for both in the README):
  1. Cross-region read replica: a single-AZ db.t4g.micro read replica in eu-west-1 created from the primary (streaming replication, RPO of seconds under demo load). On failover it is promoted to standalone primary, which takes minutes. This keeps the data resource always on in the recovery region, matching the whitepaper pilot light definition, and is the fast RTO path. It runs only during demo sessions (the whole environment is ephemeral).
  2. RDS Cross-Region Automated Backup Replication (Terraform resource `aws_db_instance_automated_backups_replication`, snapshots plus transaction logs, point-in-time restore in eu-west-1). This is the corruption protection layer: a replica faithfully replicates corrupted or deleted data, so PITR backups are what allow rewinding to the last good state, per the whitepaper caveat. Cost is cents.
- The failover script uses replica promotion as the primary recovery path; the runbook documents PITR restore as the corruption-scenario alternative, including its expected 15-60 minute restore duration.
- ECR replication rule so the image exists in eu-west-1.

### 4.3 Failover automation
- `scripts/simulate-disaster.sh`: sets primary ECS desired_count to 0 (simulated regional app failure), then tails the Route53 health check status.
- `scripts/failover.sh`: promotes the eu-west-1 read replica to standalone primary, updates the DR task definition secret/endpoint, scales DR ECS service to 2, verifies DR ALB target health.
- `scripts/failback.sh`: reverse procedure, documented even if partially manual.
- `scripts/measure.sh`: timestamps each phase and prints measured RTO; queries the checks table for the outage window to derive observed downtime.

### 4.4 Cost rationale for paid services

Every project service is chosen intentionally. Here is why each paid service is necessary and what would break without it.

**NAT Gateway (~$0.045/hr):** ECS tasks in private subnets need internet egress to check external URLs (google.com, github.com). VPC endpoints only handle AWS API traffic (ECR, S3, CloudWatch, SSM). Without NAT, the app cannot reach external targets and becomes a blank page. Alternative: put tasks in public subnets with public IPs, but that violates the security group chain design (direct internet to task) and is not production-grade. Cost is limited to demo hours only via `enable_nat` variable.

**ALB (~$0.025/hr):** Required for load balancing across ECS tasks, health checks, and the Route53 failover target. Without ALB, there is no way to route traffic to the correct task or detect task health. Fargate tasks have dynamic IPs, so a fixed endpoint is needed. Alternative: Network Load Balancer (cheaper at ~$0.0225/hr) but lacks HTTP health checks and path-based routing needed for /healthz. ALB is the right choice.

**ECS Fargate (~$0.01/hr/task):** The compute platform for the container. The project's core premise is a containerized AWS workload with HA/DR. Alternatives: Lambda cannot run a long-lived background goroutine (30s check loop); EC2 requires OS patching and has fixed costs regardless of use. Fargate is serverless, pay-per-second, and the minimum viable choice.

**RDS Multi-AZ (~$0.026/hr for db.t4g.micro, ~$0.014/hr single-AZ):** Multi-AZ is needed only during demo sessions to show within-region database HA (automatic failover on AZ outage). During idle testing (no demo), set `multi_az = false` to run single-AZ at half the cost, fully covered by 12-month free tier if eligible. The db.t4g.micro is the smallest instance and cannot be replaced by a free alternative (Aurora Serverless v2 has a minimum cost ~$0.10/hr).

**VPC Interface Endpoints (~$0.01/hr each, 3-4 needed):** ECR (api + dkr), CloudWatch Logs, SSM. Without them, all AWS API traffic routes through the NAT gateway, incurring NAT data processing fees ($0.045/GB) that exceed endpoint costs at even moderate traffic. Gateway endpoints (S3, DynamoDB) are free. Interface endpoints are the cost-optimal choice for AWS API access from private subnets.

**SSM Parameter Store ($0.05/parameter/month):** Stores the DB password. Required by Hard Rule #8 (no secrets in code or state). Chosen over Secrets Manager ($0.40/secret/month) because this project has exactly one static secret with no rotation requirement. If rotation were needed later, switching to Secrets Manager is a one-line change.

### 4.5 Route53
- Failover routing policy: PRIMARY record aliased to eu-central-1 ALB with an attached Route53 health check on the primary ALB `/healthz` path; SECONDARY record aliased to eu-west-1 ALB. Health-check-driven failover is a data plane operation, which is why it is preferred over manual record edits (control plane). State this in the README.
- If no registered domain is available: create a Route53 private-cost-free public hosted zone is not possible without a domain, so fallback plan: buy the cheapest domain (approx 3-12 EUR/year, e.g. a .de or .click via Route53) OR demonstrate failover at the health-check plus script level and document the DNS layer with the exact Terraform code that would bind it. Prefer buying the cheap domain; it makes the demo real. Decision to be confirmed with Sagar at Milestone 4 start.

### 4.6 Monitoring
- CloudWatch alarms: ALB 5xx count, ALB healthy host count < 1, ECS running task count < desired, RDS CPU > 80, RDS free storage low. All alarms notify one SNS topic with email subscription.
- EventBridge rule on ECS `SERVICE_DEPLOYMENT_FAILED` -> same SNS topic (circuit breaker visibility).
- OpenTelemetry/Prometheus: run a single-container Grafana + Prometheus on the same ECS cluster ONLY during demo sessions (separate Terraform module, disabled by default via variable) OR run Prometheus + Grafana locally via docker-compose scraping the public `/metrics` endpoint during the demo. Default to the local docker-compose option, it is free and sufficient for the recording. Document both.

### 4.7 ECS deployment safety
- Deployment circuit breaker enabled with rollback = true.
- Use the configurable threshold feature (July 2026): fixed failure count threshold set low (e.g. 2-3) in this environment so the broken-deploy demo rolls back within minutes instead of tens of minutes. Note in README that with default thresholds and desired_count 1-2, rollback can take far longer, and cite why the low fixed threshold was chosen for a demo environment.

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
│   ├── architecture.md       # diagram (draw.io / mermaid) + decisions
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
- [ ] Modules: vpc, alb, ecs-service, rds, ecr per section 4.1. Compose in environments/prod.
- [ ] VPC endpoints for ECR/S3/Logs/Secrets Manager; single NAT gateway behind a boolean variable `enable_nat` (default true for demo, document cost).
- [ ] Push image to ECR manually for this milestone (CI comes in M3).
- [ ] ECS service with circuit breaker enabled per 4.6.
Acceptance criteria:
- [ ] `terraform apply` from zero completes in one run with no manual steps.
- [ ] App reachable via ALB DNS, /status shows checks flowing, self-check target (SELF_URL) green.
- [ ] Kill one task manually (aws ecs stop-task): ALB marks target unhealthy, ECS replaces it, service recovers without intervention. Save the timeline as evidence for docs.
- [ ] RDS is Multi-AZ (verify via `aws rds describe-db-instances`).
- [ ] Security group chain verified: direct requests to task IP and DB from the internet fail.
- [ ] `terraform destroy` completes clean; `aws resourcegroupstaggingapi get-resources` filtered by project tag returns nothing in eu-central-1 (except bootstrap).
- [ ] Record apply-to-healthy wall time; it becomes the "environment rebuild time" claim in the README (this is itself the backup and restore DR baseline).

### Milestone 3: CI/CD, monitoring, deployment safety (2 days)
Tasks:
- [ ] terraform.yml workflow: fmt-check, validate, tflint, checkov, plan on PR with plan output posted as PR comment, apply on merge to main (manual approval environment gate).
- [ ] app.yml workflow: test, build, push to ECR (OIDC federation for GitHub Actions role, no long-lived AWS keys), update ECS service.
- [ ] monitoring module: CloudWatch alarms + SNS + EventBridge rule per 4.5.
- [ ] observability/docker-compose.yml: Prometheus scraping the public /metrics, Grafana with one provisioned dashboard built to be screenshot-ready for the README and demo recording.
Acceptance criteria:
- [ ] A PR with a Terraform change shows plan as a comment; merge applies it.
- [ ] A code change deploys to ECS via pipeline with zero manual steps.
- [ ] Broken-image demo: push an image that exits on start; circuit breaker (low fixed threshold) trips, rollback completes, SNS email arrives, service stays healthy on old version. Record it, measure rollback duration.
- [ ] Grafana dashboard shows live data during a demo session.

### Milestone 4: Disaster recovery (2-3 days)
Tasks:
- [ ] environments/dr composing the same modules: VPC with endpoints, ALB, ECS (desired_count 0), ECR replication.
- [ ] Cross-region read replica (single-AZ db.t4g.micro) in eu-west-1 plus `aws_db_instance_automated_backups_replication` from prod RDS to eu-west-1 (both mechanisms per 4.2).
- [ ] Route53 failover records + health check per 4.4 (confirm domain decision with Sagar first).
- [ ] Scripts: simulate-disaster.sh, failover.sh (replica promotion path), failback.sh, measure.sh.
- [ ] runbook-failover.md documenting each step, expected duration, and verification commands, including the PITR restore procedure as the corruption-scenario alternative with its 15-60 minute expected duration.
Acceptance criteria:
- [ ] Both environments apply cleanly from zero.
- [ ] Read replica in eu-west-1 shows replication lag under 30 seconds at demo load (`aws rds describe-db-instances` / ReplicaLag metric).
- [ ] Replicated automated backups visible in eu-west-1 (`aws rds describe-db-instance-automated-backups --region eu-west-1`).
- [ ] Dry run of failover.sh promotes the replica to a working standalone database whose data includes checks written in the primary shortly before the drill (bounds RPO).
- [ ] Route53 (or documented equivalent) flips to SECONDARY when primary /healthz fails.

### Milestone 5: The drill, the evidence, the writeup (2 days)
Tasks:
- [ ] Full disaster drill end to end: traffic on primary -> simulate-disaster.sh -> detection -> failover.sh -> DR serving traffic. measure.sh captures timestamps. Run at least twice; report the numbers honestly (both runs, not just the better one).
- [ ] Query the checks table in DR for the outage window; screenshot/export as evidence.
- [ ] Record terminal + Grafana + status page side by side; produce demo.gif (short) and demo.mp4 (full).
- [ ] docs/postmortem.md: timeline, detection, impact, measured RTO and RPO vs pilot light targets (RPO minutes, RTO tens of minutes per Well-Architected), what would be improved (e.g. warm standby trade-off, automation gaps).
- [ ] docs/architecture.md with diagram (mermaid in-repo plus one exported PNG).
- [ ] Final README: pitch, diagram, demo GIF at top, measured RTO/RPO, cost notes (per-session cost, why ephemeral), design decisions (single NAT, desired_count 0 vs not-deployed, data plane failover rationale, low circuit breaker threshold rationale), how to run everything.
- [ ] Destroy both environments; verify zero remaining resources in both regions except bootstrap.
Acceptance criteria:
- [ ] README contains only measured numbers, no estimates presented as measurements.
- [ ] A stranger can rebuild the entire project from the README in one sitting.
- [ ] Total AWS bill for the whole build reviewed and stated in the README cost section.

## 7. Timeline

Roughly three weeks part-time: M0+M1 week 1, M2+M3 week 2, M4+M5 week 3. Hard cap on app work (1 day). If any milestone runs 50 percent over, cut optional scope (HTTPS, hosted Grafana on ECS, failback automation) before extending time.

## 8. CV Bullet (final, use only after Milestone 5)

"Designed and demonstrated a highly available AWS workload (personal project): Terraform-provisioned ECS Fargate across two AZs with Multi-AZ RDS, CloudWatch and OpenTelemetry monitoring, GitHub Actions CI/CD with automated rollback, and cross-region pilot light disaster recovery with Route53 failover, achieving a measured RTO of X minutes with point-in-time recovery."

Replace X with the measured value. Keep the personal project label.

## 9. Out of Scope (do not let agents add these)

Custom auth, user accounts, alerting rules inside the app, Kubernetes/EKS, multi-account setups, service mesh, HTTPS/ACM (optional stretch only), AI/LLM features, any always-on infrastructure beyond the bootstrap state bucket.
