# Milestone 3 Evidence

Verified on 2026-07-17 against AWS account `926883320788`, region `eu-central-1`. Prod environment was fully destroyed after M2; this session rebuilt it from zero (foundation apply, image push, service apply) before starting M3 work, per the M2 evidence sequence.

## Rebuild Summary

- Phase 1 (foundation, `deploy_service=false`, `multi_az=false`): 54 resources, ~11 minutes (RDS creation dominant).
- Monitoring + github-oidc modules: 30 resources, applied immediately after phase 1 (no app image dependency).
- Image built (`docker build --platform linux/arm64`), pushed to ECR: digest `sha256:ea1e5b66fc916b0f5b921533bd19f7afa2cbea73721fda5e20bfcfa941e4d092`.
- Phase 2 (`deploy_service=true`): 2 resources, app service reached 2/2 running.
- `multi_az=false` for this rebuild since Multi-AZ failover mechanics were already proven in M2; kept off here for cost.

## Monitoring Module (OTel Collector, Prometheus, Grafana)

All three run as separate Fargate ECS services (256 CPU / 512 MB, ARM64, desired_count=1) in the app private subnets, connected over an AWS Cloud Map private DNS namespace (`sentinel-aws-dr-prod.internal`). No public entry point; Grafana is reached only via `aws ecs execute-command` (SSM), matching the plan's "SSM port-forward for the demo" option.

**Bug found and fixed during verification:** the Grafana container tried to write `/var/lib/grafana/dashboards/sentinel.json` before that directory existed (only `/etc/grafana/provisioning/*` is pre-created in the image). Fixed with an explicit `mkdir -p` in the container's startup script; new task definition revision deployed cleanly.

**Live verification** (via `aws ecs execute-command` into the Grafana task, querying over the internal namespace):
- Prometheus query `sentinel_target_up` returned real data: `{target="https://github.com"} = 1`, `{target="https://www.google.com"} = 1`.
- Grafana `/api/health`: `{"database":"ok"}`.
- Grafana `/api/search?query=Sentinel`: the provisioned "Sentinel" dashboard (`uid=sentinel-status`) is present.
- Grafana `/api/datasources`: Prometheus datasource provisioned, `isDefault=true`, pointed at `http://prometheus.sentinel-aws-dr-prod.internal:9090`.

`session-manager-plugin` was installed locally without root (extracted the AWS-provided zip bundle's `bin/` directly into `~/.local/bin`) since the Homebrew cask installer required sudo that wasn't available in this session.

## Alerting (CloudWatch alarms, SNS, EventBridge)

Five alarms created and confirmed `OK`: `alb-5xx`, `alb-healthy-hosts`, `ecs-running-tasks`, `rds-cpu`, `rds-free-storage`. One SNS topic (`sentinel-aws-dr-prod-alerts`) with an email subscription to the project owner. One EventBridge rule on the ECS deployment circuit breaker's failure event.

**Two real bugs found and fixed during verification, not just at apply time:**

1. **SNS topic policy missing a CloudWatch statement.** The topic policy only granted `events.amazonaws.com` (EventBridge) publish rights. A forced alarm state change (`aws cloudwatch set-alarm-state`) showed `"Failed to execute action ...sentinel-aws-dr-prod-alerts"` in the alarm history. Fixed by adding an `AllowCloudWatchAlarmsPublish` statement for `cloudwatch.amazonaws.com`. Reverified: `"Successfully executed action ...sentinel-aws-dr-prod-alerts"`.
2. **EventBridge rule used the wrong field name.** The rule matched `detail.eventType = ["SERVICE_DEPLOYMENT_FAILED"]`, but a temporary catch-all debug rule (source=`aws.ecs`, no detail filter) captured the real event shape: `detail-type` is `"ECS Deployment State Change"`, and the specific value lives in `detail.eventName` (`SERVICE_DEPLOYMENT_IN_PROGRESS` / `COMPLETED` / `FAILED`); `detail.eventType` is only a severity level (`INFO`/`ERROR`). Fixed the rule to match `eventName`. Reverified with a clean broken-image redeploy: the debug rule captured `eventType=ERROR, eventName=SERVICE_DEPLOYMENT_FAILED` at the same moment the real Terraform-managed rule's `TriggeredRules` CloudWatch metric went to 1.

**Update 2026-07-17:** the SNS email subscription is now confirmed (`aws sns list-subscriptions-by-topic` returns a real subscription ARN, not `PendingConfirmation`). Original state at first writing: the first confirmation email's link expired unused (status showed `"Deleted"`); the subscription was replaced via `terraform apply -replace` to resend it, and the project owner then clicked the new link. The alarm/EventBridge/SNS-publish mechanics were confirmed working independently of that click.

## Broken-Image Circuit Breaker Test

Run twice (`sentinel-aws-dr-prod:4`, an `alpine` image whose entrypoint exits 1 immediately):

| Run | update-service | deployment failed / rollback initiated | duration |
|---|---|---|---|
| 1 | 21:43:24Z | 21:47:22Z | 3m58s |
| 2 (clean, post-fix) | 21:55:59Z | 21:59:00Z | 3m01s |

Both runs: old revision (`:3`) kept serving throughout, service never dropped below desired count of healthy targets, ECS automatically rolled back to `:3`, no manual intervention. Provider-supported default failure threshold, not a custom one (per Hard Rule / section 4.7).

## Database-Unavailable Repeat Test

Used `aws rds reboot-db-instance` (no `--force-failover`; Multi-AZ is off for this rebuild, and forced failover was already proven in M2) to control cost.

- `/healthz` via ALB: one `503`, then `200` within 5-10 seconds.
- App logs: `"healthz: db ping failed", "error":"driver: bad connection"` then `"error":"pq: the database system is starting up (57P03)"`, clean structured errors with no DB password or connection string in the log lines.
- RDS returned to `available` and app reconnected automatically without redeployment.

## app.yml / GitHub OIDC

- `terraform/modules/github-oidc`: OIDC provider for `token.actions.githubusercontent.com` (thumbprints fetched live via `openssl s_client` rather than a possibly-stale copied constant), IAM role scoped to this repo (`repo:sagar-uprety/sentinal-aws-disastor-recovery:*`), least-privilege policy (ECR push to one repo, register/describe task definitions, update one ECS service, `PassRole` on the task execution role only).
- `AWS_ROLE_ARN` repo variable set via `gh variable set` to `arn:aws:iam::926883320788:role/sentinel-aws-dr-prod-github-actions`.
- `.github/workflows/app.yml` written: test job (`go test ./...`), build-and-deploy job (OIDC login, build/push by git-SHA tag, resolve digest, render + deploy task definition via `aws-actions/amazon-ecs-deploy-task-definition`). Passed `go test ./...` locally and the checkov/actionlint pre-commit checks. **Not yet exercised by a real GitHub Actions run**; that requires merging this branch to `main`.

## Cost

- AWS Budgets: "100$ limit" (annual) at $0, "My Monthly Cost Budget" ($30/month) at $0.84; both pre-date today's rebuild, and Cost Explorer/Budget actuals lag roughly a day.
- Infracost static scan (`infracost scan`, via the repo's pre-commit hook) of the prod environment: **$113/month** projected if every resource ran continuously for a full month. This under-counts by roughly $20/month: the scan uses variable defaults (`deploy_service=false`), so it excludes the Sentinel app's own 2-task ECS service, priced comparably to the monitoring tasks (~$10/task/month). Realistic continuous-month run-rate is closer to **$130-135/month**.
  - Breakdown: NAT Gateway $38, 4 ECS services / 5 Fargate tasks total (3 monitoring services at 1 task each + the app service at 2 tasks) ~$52, ALB $20, RDS single-AZ $17, 2 EIPs $7, alarms ~$1.
  - This is a **projected run-rate if left running for a full month**, not actual spend. The project is designed to be ephemeral (Hard Rule 4): the real cost of this session (a few hours, build + verify + evidence capture) is a small fraction of that. **Recommend destroying the environment (`terraform destroy` in `dr` then `prod`) once evidence capture for this milestone is complete**, rather than leaving it running, since a few days of continuous runtime would meaningfully eat into the $30/month budget.

## Outstanding M3 Items

- ~~`app.yml` not yet exercised by a real GitHub Actions run (needs PR merge to `main`).~~ Verified 2026-07-17: after the M3 PRs merged, run `29540534462` (workflow_dispatch) completed successfully in 8m15s; earlier push-triggered failures were fixed by PRs #3-#6 (CI Postgres service, QEMU, cross-compile, `ecr:DescribeImages`). Task definition revision 5 shows `registeredBy = assumed-role/sentinel-aws-dr-prod-github-actions/GitHubActions`, its image digest carries the merge-commit SHA tag (`3d5a8a7...`), and the service reached `rolloutState = COMPLETED` at 2/2 running with zero manual AWS steps.
- ~~SNS email subscription needs the project owner to click the confirmation link.~~ Confirmed 2026-07-17.
- `terraform.yml` (Terraform CI/CD gate) deferred to M5 per the revised plan.
