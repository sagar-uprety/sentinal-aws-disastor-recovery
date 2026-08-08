# Milestone 7 Evidence

Milestone 7 is now deployed and verified live, including one full HA plus regional failover/failback drill (2026-08-08). Historical M0-M6 measurements remain evidence for the former coupled architecture only and are not conflated with the results below.

## Repository Validation

Local validation run 2026-07-26. Do not treat local results as CI or live deployment evidence.

- [x] Monitor Go tests, race tests, vet, GolangCI-Lint, govulncheck, and frontend build passed through `pre-commit run --all-files`
- [x] Workload Go tests, race tests, vet, GolangCI-Lint, govulncheck, and PostgreSQL 18 integration tests passed; integration command used `TEST_DATABASE_URL` against the Compose database
- [x] ARM64 monitor and workload container builds passed; images report `linux/arm64`, user `65534:65534`, and sizes 4,099,153 and 2,894,662 bytes respectively
- [x] `terraform fmt -check -recursive terraform`
- [x] `terraform validate` for bootstrap, monitoring, prod, and DR roots
- [x] TFLint and Checkov
- [x] Shell syntax and ShellCheck for drill scripts
- [x] Workflow validation for `terraform.yml`, `monitor.yml`, `workload.yml`, and `recovery.yml`
- [ ] Independent monitoring, prod, and DR Terraform plans reviewed
- [ ] Monitoring and workload destroy plans reviewed for state isolation

Read-only unlocked live-state plans verified monitoring foundation at 61 creates with no DNS cutover or destroys, and prod migration at two token creates, workload task-definition replacement, removal of obsolete workload topology policies, certificate replacement, and no deletion of the monitor validation CNAME. DR correctly remains blocked until prod creates `/sentinel-aws-dr/prod/link-create-token`; review it after prod apply, before DR apply.

Infracost did not produce an estimate because the local OAuth refresh token is invalid. Its fail-closed hook now uses the explicit manual stage so the documented external-auth blocker does not masquerade as a failed code check; run `pre-commit run infracost-scan --hook-stage manual --all-files` after authentication and before deployment. Docker Scout scans did not run because Docker login is absent. These two checks remain incomplete.

## Deployment Evidence

- [ ] Guarded bootstrap IAM plan reviewed and explicitly approved apply retained. Not touched this session; bootstrap remains from its original apply.
- [x] `monitor-foundation` run and monitoring role output retained. Applied via `full-deploy` run [31200740992](https://github.com/sagar-uprety/sentinal-aws-disastor-recovery/actions/runs/31200740992) on 2026-08-07 (monitoring foundation + monitor deploy steps both succeeded).
- [~] `monitor.yml` publish-only digest retained. The monitor service already existed by this point (created via `full-deploy` above), so `mode=deploy` was the correct operation, not `publish-only` (that mode is for the initial pre-service bootstrap). Not literally satisfied as worded, but the equivalent live-deploy evidence exists in the next line.
- [x] `monitor-deploy` run and public monitor health retained. `monitor.yml` `mode=deploy` run [31221676825](https://github.com/sagar-uprety/sentinal-aws-disastor-recovery/actions/runs/31221676825) (M7 UI/backend fixes) and run [31230008191](https://github.com/sagar-uprety/sentinal-aws-disastor-recovery/actions/runs/31230008191) (checker DNS-cutover fix), both green, both confirmed live via `curl https://sentinel.sagaruprety.com.np/healthz` returning 200.
- [x] Existing M6 workload foundation verified for migration, or workload `foundation` run retained for a from-empty deployment. `full-deploy` run 31200740992 applied prod foundation from empty state (fresh VPC/RDS/ECR), confirmed via live `aws` CLI state checks at the time.
- [~] `workload.yml` publish-only digest and cross-region replication retained. Same `publish-only` vs `deploy` nuance as monitor above; `deploy` mode was correct since the service already existed. Cross-region task-definition replication to DR is confirmed instead (next line).
- [x] Workload `deploy` run with prod healthy and DR desired count zero retained. `workload.yml` `mode=deploy` run [31221678424](https://github.com/sagar-uprety/sentinal-aws-disastor-recovery/actions/runs/31221678424), green, prod verified 200 with 2/2 tasks, DR task definition synced with desired count 0.
- [ ] Regional SSM parameter metadata and write-only applied-state checks retained without secret values. Not re-verified this session (was verified historically in M6).

## Live Gates

- [x] Monitor remains available during ECS task replacement. Confirmed during the regional failover/failback (`monitor_available_during_outage`, `monitor_available_during_failover`, `monitor_available_after_traffic_switch` events, drill-events.log). Not separately instrumented during the standalone HA task-stop sub-test specifically. The monitor was never restarted or touched at any point across the whole session, so it was available throughout, but that specific narrow window has no dedicated logged check.
- [x] Monitor remains available during controlled AZ capacity loss. Same evidence and same caveat as above (no dedicated logged check bracketing the standalone HA AZ sub-test specifically).
- [x] Monitor remains available during RDS Multi-AZ failover. Same evidence and same caveat as above (no dedicated logged check bracketing the standalone HA db-failover sub-test specifically).
- [x] Monitor records regional workload outage and recovery. Directly evidenced: the monitor's own `/status` history recorded the outage and recovery in real time, and a real bug in that recording (stale DNS-cached connection after cutover) was found and fixed live because the monitor's data was actually being watched and cross-checked against reality.
- [x] Prod-created link survives failover. Every link present on primary before the outage (not a sample of one) verified present in DR after promotion (`pre_outage_link_verified_in_dr`, drill-events.log).
- [x] DR-created link survives failback. `dr-drill-20260807224142` verified present on restored, promoted prod (`failback.sh ready` output).
- [x] Fresh M7 RTO and RPO evidence retained. RTO 666s, RPO 26.0s (real CloudWatch `ReplicaLag`, not a placeholder). Target was 30min / 60s respectively.
- [x] Failback reset restores prod writer, DR replica, and DR desired count zero. Confirmed via `failback.sh verify-reset` output and live AWS Console screenshots (prod Primary/eu-central-1, DR Replica/eu-west-1 actively Replicating).
- [~] Monitoring resources remain unchanged through workload failover, reset, and destroy plans. The failover-and-reset portion is confirmed (monitor never restarted or touched). No destroy plan was run this session (workload teardown is a separate, later, deliberately-deferred task) so that specific clause is not yet evidenced.

## Live Drill Results (2026-08-08)

Full drill sequence executed live on the isolated two-plane architecture, monitor continuously observed throughout: 3 HA tests, 1 regional failover with ARC traffic switch, 1 full failback with topology reset.

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

One transient AWS CLI credential failure interrupted `failover.sh` after the underlying RDS promotion and DR verification work had already succeeded; diagnosed live via `aws rds describe-events`, confirmed no state was lost, and the remaining verification steps were completed manually before continuing.

**Bugs found live, in scope of this drill:**
1. **Fixed and redeployed** ([PR #35](https://github.com/sagar-uprety/sentinal-aws-disastor-recovery/pull/35)): monitor's checker reused a pooled HTTP keep-alive connection across a DNS-driven region cutover (Go's 90s idle timeout never elapsed at a 30s check interval), so it kept reporting the pre-cutover region as down for minutes after traffic had genuinely moved.
2. **Fixed** ([PR #36](https://github.com/sagar-uprety/sentinal-aws-disastor-recovery/pull/36)): `measure.sh` read a `traffic_switch_requested` event name that collides between the regional-failover switch and the later failback switch-back, producing a negative duration on a post-failback report. Also fixed in the same PR: a case-sensitivity bug in `switch-traffic.sh` suppressed its own next-step hint message (cosmetic only).
3. **Not a code bug, unresolved**: both DR's and prod's RDS instances, after promotion and Multi-AZ conversion, reported `SecondaryAvailabilityZone: null` via the API despite `MultiAZ: true` and a clean "finished" event in AWS's own event log. The `MultiAZ` boolean check that actually gates the runbook passed correctly both times; this needs a manual AWS Console check to confirm the standby is real, not a functional blocker.

## Deferred

- [ ] Canonical architecture diagram update. Deferred by owner instruction and not complete.
