# Milestone 7 Evidence

Milestone 7 is now deployed and verified live, including one full HA plus regional failover/failback drill (2026-08-08). Historical M0-M6 measurements remain evidence for the former coupled architecture only and are not conflated with the results below.

## Repository Validation

Local validation run 2026-07-26. Do not treat local results as CI or live deployment evidence.

- [x] Sentry Go tests, race tests, vet, GolangCI-Lint, govulncheck, and frontend build passed through `pre-commit run --all-files`
- [x] Workload Go tests, race tests, vet, GolangCI-Lint, govulncheck, and PostgreSQL 18 integration tests passed; integration command used `TEST_DATABASE_URL` against the Compose database
- [x] ARM64 sentry and workload container builds passed; images report `linux/arm64`, user `65534:65534`, and sizes 4,099,153 and 2,894,662 bytes respectively
- [x] `terraform fmt -check -recursive terraform`
- [x] `terraform validate` for bootstrap, monitoring, primary, and secondary roots
- [x] TFLint and Checkov
- [x] Shell syntax and ShellCheck for drill scripts
- [x] Workflow validation for `terraform.yml`, `sentry.yml`, `workload.yml`, and `recovery.yml`
- [x] Independent monitoring, primary, and secondary Terraform plans reviewed, see Update 2026-08-14 below
- [x] Monitoring and workload destroy plans reviewed for state isolation, see Update 2026-08-14 below

Read-only unlocked live-state plans verified monitoring foundation at 61 creates with no DNS cutover or destroys, and primary migration at two token creates, workload task-definition replacement, removal of obsolete workload topology policies, certificate replacement, and no deletion of the sentry validation CNAME. Secondary correctly remains blocked until primary creates `/sentinel-aws-secondary/primary/link-create-token`; review it after primary apply, before secondary apply.

Infracost did not produce an estimate because the local OAuth refresh token is invalid. Its fail-closed hook now uses the explicit manual stage so the documented external-auth blocker does not masquerade as a failed code check; run `pre-commit run infracost-scan --hook-stage manual --all-files` after authentication and before deployment. Docker Scout scans did not run because Docker login is absent. These two checks remain incomplete.

## Deployment Evidence

- [ ] Guarded bootstrap IAM plan reviewed and explicitly approved apply retained. Not touched this session; bootstrap remains from its original apply.
- [x] `sentry-foundation` run and monitoring role output retained. Applied via `full-deploy` run [31200740992](https://github.com/sagar-uprety/sentinal-aws-disastor-recovery/actions/runs/31200740992) on 2026-08-07 (monitoring foundation + sentry deploy steps both succeeded).
- [~] `sentry.yml` publish-only digest retained. The sentry service already existed by this point (created via `full-deploy` above), so `mode=deploy` was the correct operation, not `publish-only` (that mode is for the initial pre-service bootstrap). Not literally satisfied as worded, but the equivalent live-deploy evidence exists in the next line.
- [x] `sentry-deploy` run and public sentry health retained. `sentry.yml` `mode=deploy` run [31221676825](https://github.com/sagar-uprety/sentinal-aws-disastor-recovery/actions/runs/31221676825) (M7 UI/backend fixes) and run [31230008191](https://github.com/sagar-uprety/sentinal-aws-disastor-recovery/actions/runs/31230008191) (checker DNS-cutover fix), both green, both confirmed live via `curl https://sentinel.sagaruprety.com.np/healthz` returning 200.
- [x] Existing M6 workload foundation verified for migration, or workload `foundation` run retained for a from-empty deployment. `full-deploy` run 31200740992 applied primary foundation from empty state (fresh VPC/RDS/ECR), confirmed via live `aws` CLI state checks at the time.
- [~] `workload.yml` publish-only digest and cross-region replication retained. Same `publish-only` vs `deploy` nuance as sentry above; `deploy` mode was correct since the service already existed. Cross-region task-definition replication to secondary is confirmed instead (next line).
- [x] Workload `deploy` run with primary healthy and secondary desired count zero retained. `workload.yml` `mode=deploy` run [31221678424](https://github.com/sagar-uprety/sentinal-aws-disastor-recovery/actions/runs/31221678424), green, primary verified 200 with 2/2 tasks, secondary task definition synced with desired count 0.
- [ ] Regional SSM parameter metadata and write-only applied-state checks retained without secret values. Not re-verified this session (was verified historically in M6).

## Live Gates

- [x] Sentry remains available during ECS task replacement. Confirmed during the regional failover/failback (`sentry_available_during_outage`, `sentry_available_during_failover`, `sentry_available_after_traffic_switch` events, drill-events.log). Not separately instrumented during the standalone HA task-stop sub-test specifically. The sentry was never restarted or touched at any point across the whole session, so it was available throughout, but that specific narrow window has no dedicated logged check.
- [x] Sentry remains available during controlled AZ capacity loss. Same evidence and same caveat as above (no dedicated logged check bracketing the standalone HA AZ sub-test specifically).
- [x] Sentry remains available during RDS Multi-AZ failover. Same evidence and same caveat as above (no dedicated logged check bracketing the standalone HA db-failover sub-test specifically).
- [x] Sentry records regional workload outage and recovery. Directly evidenced: the sentry's own `/status` history recorded the outage and recovery in real time, and a real bug in that recording (stale DNS-cached connection after cutover) was found and fixed live because the sentry's data was actually being watched and cross-checked against reality.
- [x] Primary-created link survives failover. Every link present on primary before the outage (not a sample of one) verified present in secondary after promotion (`pre_outage_link_verified_in_secondary`, drill-events.log).
- [x] secondary-created link survives failback. `secondary-drill-20260807224142` verified present on restored, promoted primary (`failback.sh ready` output).
- [x] Fresh M7 RTO and RPO evidence retained. RTO 666s, RPO 26.0s (real CloudWatch `ReplicaLag`, not a placeholder). Target was 30min / 60s respectively.
- [x] Failback reset restores primary writer, secondary replica, and secondary desired count zero. Confirmed via `failback.sh verify-reset` output and live AWS Console screenshots (primary Primary/eu-central-1, secondary Replica/eu-west-1 actively Replicating).
- [x] Monitoring resources remain unchanged through workload failover, reset, and destroy plans. The failover-and-reset portion is confirmed (sentry never restarted or touched). The destroy portion is confirmed via the actual combined-destroy run, see Update 2026-08-14 below: destroying secondary then primary then monitoring left bootstrap untouched, and each root's plan/destroy-plan output contains only that root's own resources.

## Live Drill Results (2026-08-08)

Full drill sequence executed live on the isolated two-plane architecture, sentry continuously observed throughout: 3 HA tests, 1 regional failover with ARC traffic switch, 1 full failback with topology reset.

| Test | Result |
|---|---|
| HA: stop 1 ECS task | 42s recovery, restored 2/2 across both AZs |
| HA: stop all tasks in 1 AZ | 55s recovery, restored 2/2 across both AZs |
| HA: forced RDS Multi-AZ failover | 412s recovery, writer moved `eu-central-1a`→`eu-central-1b`, 1 five-second health sample missed |
| Regional failover RTO | 666s (target 30min) |
| Regional failover RPO | 26.0s, real CloudWatch `ReplicaLag` (target 60s) |
| Failback duration | 851s / 14m11s (writes frozen through primary traffic re-verified) |
| Protected `recovery.yml` phases | ~29-30min each (`failback-prepare`, `failback-reset`); the slowest part of the whole drill by far, inherent to RDS recreate-as-replica time |

Full timeline retained in `drill-events.log` (not checked into the repo; local operator artifact).

One transient AWS CLI credential failure interrupted `failover.sh` after the underlying RDS promotion and secondary verification work had already succeeded; diagnosed live via `aws rds describe-events`, confirmed no state was lost, and the remaining verification steps were completed manually before continuing.

**Bugs found live, in scope of this drill:**
1. **Fixed and redeployed** ([PR #35](https://github.com/sagar-uprety/sentinal-aws-disastor-recovery/pull/35)): sentry's checker reused a pooled HTTP keep-alive connection across a DNS-driven region cutover (Go's 90s idle timeout never elapsed at a 30s check interval), so it kept reporting the pre-cutover region as down for minutes after traffic had genuinely moved.
2. **Fixed** ([PR #36](https://github.com/sagar-uprety/sentinal-aws-disastor-recovery/pull/36)): `measure.sh` read a `traffic_switch_requested` event name that collides between the regional-failover switch and the later failback switch-back, producing a negative duration on a post-failback report. Also fixed in the same PR: a case-sensitivity bug in `switch-traffic.sh` suppressed its own next-step hint message (cosmetic only).
3. **Not a code bug, unresolved**: both secondary's and primary's RDS instances, after promotion and Multi-AZ conversion, reported `SecondaryAvailabilityZone: null` via the API despite `MultiAZ: true` and a clean "finished" event in AWS's own event log. The `MultiAZ` boolean check that actually gates the runbook passed correctly both times; this needs a manual AWS Console check to confirm the standby is real, not a functional blocker.

## Update 2026-08-14: state-isolation proof and local re-lint

The owner had already destroyed all workload/monitoring infrastructure outside this session, via the reviewed `terraform.yml` `operation=destroy` dispatch (run [31231322585](https://github.com/sagar-uprety/aws-pilotlight-multi-region-dr/actions/runs/31231322585), 2026-08-08, secondary then primary then monitoring, gated by typed `confirm_destroy=DESTROY`). This turned out to be the cleanest possible substrate for the still-open state-isolation gate:

- `terraform state list` against the live backend returns nothing for `monitoring`, `primary`, or `secondary`, all three states are genuinely empty, confirmed independently by `aws ecs list-clusters` and `aws rds describe-db-instances` returning no results in either region. Bootstrap's state is untouched (Route53 zone, OIDC roles, state bucket, lock table all present).
- Fresh `terraform plan` per root: monitoring 61 to add, primary 76 to add (both `-var` combinations matching each root's last-deployed config), secondary blocked on primary's now-nonexistent data sources (expected, secondary's only cross-state dependencies are `aws_ecs_service.primary`, `aws_ecs_task_definition.primary`, `aws_db_instance.primary`, `aws_lb.primary`, two SSM parameters under `/pilotlight/primary/...`, and `aws_ecr_repository.app`; none reference monitoring).
- Grepping each plan's resource-address list for the other plane's resource types (`aws_db_instance`, `shortener`, `aws_dynamodb_table`, sentry ECR/ECS/ALB) found zero hits in either direction. Primary's plan does contain `module.monitoring.*` addresses, but that's primary's own local CloudWatch-alarms/SNS submodule (unrelated naming collision with the isolated sentry plane), not the isolated sentry.
- `terraform plan -destroy` against all three empty states returns "No changes. No objects need to be destroyed", the plainest possible proof that neither state holds resources belonging to the other plane.

Also re-ran the local validation checklist post-M9-rename: `terraform fmt -check -recursive` clean, `terraform validate` clean (4 environments), `tflint --recursive` clean, `pre-commit run checkov --all-files` passed. Infracost skipped (local OAuth token unavailable; owner decision, not a failure).

## Deferred

- [x] Canonical architecture diagram update. Was deferred at the time this file was originally written, then completed later the same day (2026-08-08) as part of the M9 rebrand's diagram pass, see `plan.md` M7 acceptance criteria and M9 tasks for detail. Not re-deferred; this line is now stale relative to that later work but is left as an accurate record of the state at 2026-08-08 evening.
