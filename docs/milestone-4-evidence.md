# Milestone 4 Evidence

Verified on 2026-07-17 against AWS account `926883320788`, regions `eu-central-1` (prod) and `eu-west-1` (dr). This session rebuilt prod from zero, reconciled interrupted-apply drift, built the DR environment, delegated Route53 through Cloudflare, exercised ARC, completed an isolated PITR restore, and ran a real failover rehearsal. The reverse-replication leg of failback began but was intentionally stopped before topology reset; all workload resources were then destroyed to control cost.

## Prod Rebuild

Two-phase M2 sequence: foundation apply (`deploy_service=false`) then service apply (`deploy_service=true`) after building and pushing the app image.

**Incident: the foundation apply's first attempt kept running after being interrupted.** A `terraform apply` invoked interactively was cancelled mid-run from the tool-call layer, but the underlying process continued executing against AWS — it created a NAT gateway, the ALB, the RDS instance, and a Cloud Map/Route53 private DNS namespace before the interruption prevented it from writing any of that to state. A second, fresh apply attempt then collided with those orphaned resources (`DBInstanceAlreadyExists`, `EIP already associated`, `ConflictingDomainExists`).

Reconciliation, in order:
1. `terraform force-unlock` on the stale S3 native lock left behind.
2. Deleted the one resource that was genuinely a duplicate failure (a second NAT gateway attempt that failed because the EIP was already attached to the orphan).
3. Cross-referenced the orphan NAT gateway's EIP allocation IDs against `terraform state show` for `aws_eip.nat[0/1]` to confirm it was the real, legitimate one (not a duplicate) before importing.
4. `terraform import` for the NAT gateway, the ALB (matched by its unique ARN — only one existed), the Cloud Map namespace (`NAMESPACE_ID:VPC_ID` format), and the RDS instance.
5. Re-ran `terraform plan`: 3 resources showed tag-only drift (imported resources getting `default_tags` applied), 0 destroys. Applied cleanly.

No orphaned or duplicate AWS resources were left behind; verified via `aws ec2 describe-nat-gateways`, `aws elbv2 describe-load-balancers`, and `aws rds describe-db-instances` all showing exactly one of each.

**Separately:** adding `count` to `aws_db_instance.main` in the `rds` module (to support the replica variant, see below) changed that resource's state address from `aws_db_instance.main` to `aws_db_instance.main[0]`. Ran `terraform state mv` before the next plan to avoid a destroy/recreate of the real production database.

Final state: `terraform plan` on prod — `No changes. Your infrastructure matches the configuration.`

**App verification** (via the ALB, `sentinel-aws-dr-prod-alb-1843459046.eu-central-1.elb.amazonaws.com`):
- `/healthz` → 200
- `/status` → both checks (`github.com`, `google.com`) up, 100% 24h uptime
- `/` → 200
- ECS service: 2/2 tasks running

## RDS Module Extension (Cross-Region Replica Support)

The `rds` module only supported a standalone master instance. Added:
- `replicate_source_db_arn` (default `null`) and `kms_key_id` variables.
- `aws_db_instance.main` gated to `count = replicate_source_db_arn == null ? 1 : 0`.
- New `aws_db_instance.replica` (`count = replicate_source_db_arn != null ? 1 : 0`): `replicate_source_db` set to the source ARN (cross-region replicas require the ARN, not the identifier — same-region replicas can use identifier, confirmed via the AWS provider's v6.33.0 upgrade guide), storage/engine/credentials all inherited from the source and therefore omitted.
- Outputs (`endpoint`, `address`, `port`, new `arn`) unified across both variants with `one(concat(...))`.

## ECR Replication and Automated Backups Replication (prod-side)

Both added to `environments/prod/main.tf`:
- `aws_ecr_replication_configuration` — registry-level (one per account), destination `eu-west-1`.
- `aws_db_instance_automated_backups_replication`, `provider = aws.dr`, `kms_key_id` from the AWS-managed `alias/aws/rds` key in eu-west-1 (not a customer-managed key — no per-key fee, matches the project's existing pattern for SSM/Performance Insights), `retention_period = 7`.

**Gap found and fixed:** the app image had been built and pushed to prod ECR *before* the replication configuration existed. AWS ECR only replicates images pushed after a replication rule is configured — it does not backfill existing images. `aws ecr describe-images --region eu-west-1` returned `RepositoryNotFoundException` even though the replication rule was active and prod's task definition already referenced that digest. Fixed by re-pushing the same image under a new tag (`replicate-trigger`) to force a fresh push event; confirmed the destination repository and the exact digest (`sha256:8befbe48e3f5859e9da76a997fd4825b0f6282eb3e5200725f7a85fda0356776`) both appeared in eu-west-1 shortly after.

Automated backups replication: `aws rds describe-db-instance-automated-backups --region eu-west-1` shows `sentinel-aws-dr-prod`, retention `7`, status `replicating` — retention matches the primary, not just "a backup exists."

## DR Environment

`environments/dr` composes `vpc`, `alb`, `ecs-service` (`deploy_service=true`, `desired_count=0`), `monitoring`, and `rds` (as a replica) — the same modules as prod, reading prod's outputs via `data.terraform_remote_state` (ECR URL, image digest, RDS ARN/class/engine version, DR-region SSM parameter ARN) rather than duplicating values.

A `check` block guards replica creation on engine-version match: both regions resolved PostgreSQL `18.4` via `data.aws_rds_engine_version`.

Applied: 78 resources, ~20 minutes wall time (the cross-region RDS replica dominated at 19m17s; everything else finished in under 2 minutes). `terraform plan` afterward: no changes.

**Verification:**
- `aws rds describe-db-instances --region eu-west-1 --db-instance-identifier sentinel-aws-dr-dr`: status `available`, source ARN matches prod's instance, `db.t4g.micro`, engine `18.4`, `MultiAZ: false` (single-AZ per the M4 spec — Multi-AZ conversion is a post-promotion step, not part of initial creation).
- CloudWatch `ReplicaLag`: spiked to ~500-600s during initial catch-up, settled to 10-17s — well under the 30s acceptance target.
- ECS service `sentinel-aws-dr-dr`: `ACTIVE`, 0/0 running (pilot-light, as designed).

**Historical cost note:** this rehearsal ran the now-removed OTel/Prometheus/Grafana Fargate stack in DR, adding roughly $25-30/month. It was removed during Milestone 5 scope review because it duplicated app data and shared the regional workload failure domain. Current DR cost estimates exclude those tasks.

## Operator Scripts

`scripts/simulate-disaster.sh`, `scripts/failover.sh`, `scripts/failback.sh`, and `scripts/measure.sh` were written and executed during the rehearsal. Those M4 revisions remain the source of the historical evidence below. A later review replaced them with hardened versions and added `switch-traffic.sh`; the current versions have passed shell syntax checks but have not run live and must be exercised in M6.

Design notes:
- `failover.sh` deliberately stops after DR readiness. The new `switch-traffic.sh` is a separate explicit gate that atomically changes both ARC controls and logs completion only after authoritative DNS plus `/topology` verify target-Region traffic.
- `failback.sh` is deliberately not a blind topology mutation. Current Terraform direction changes run as saved plans through separately protected GitHub Actions plan/apply jobs, while the script handles promotion gates and verifies replica source and lag, the known DR-written row, primary readiness, restored DR replication, pilot-light desired count, and temporary snapshot cleanup.
- `measure.sh` now isolates the newest drill segment, reports each recovery phase, measures RTO through verified public traffic, and computes row-based RPO from the same canonical target before and after promotion. Pre-promotion ReplicaLag remains separate supporting evidence.

## Cloudflare MCP

Added and documented in `docs/cloudflare-mcp-setup.md` (project-local, not committed, OAuth-authenticated). Its tools did not register in the session that added it — mid-session MCP additions require a new session to load tool schemas.

## Route53 Zone and NS Delegation (completed in a separate session)

A separate session with the Cloudflare tools loaded created the `sentinel.sagaruprety.com.np` Route53 hosted zone (`environments/dr/route53.tf`, zone ID `Z05244901B71SBS0IXLFG`) and added the NS delegation record in the Cloudflare-managed `sagaruprety.com.np` zone. Verified in this session:

```
$ dig NS sentinel.sagaruprety.com.np +short
ns-1209.awsdns-23.org.
ns-196.awsdns-24.com.
ns-1969.awsdns-54.co.uk.
ns-609.awsdns-12.net.
```

Delegation confirmed working — real Route53 nameservers, not Cloudflare's.

## Route53 Failover Module (ARC)

`terraform/modules/route53-failover`: ARC cluster, control panel, two routing controls (`primary`, `dr`), two safety rules, two `RECOVERY_CONTROL`-type health checks gating two failover A-records at `status.sentinel.sagaruprety.com.np`, plus two plain-HTTP detection-only health checks (not wired to any record). Applied with explicit project-owner approval given the $2.50/cluster-hour ARC cost.

**Bug found and fixed during live verification, not just at apply time.** The `not_both_on` safety rule was written as `rule_config { type = "ATLEAST", threshold = 1, inverted = true }`, intending "not both On." Setting the primary control On (required initial state — both controls actually default to `Off` on creation, not one On/one Off) was rejected outright:

```
ValidationException: Can't update the routing control state because of a
configured safety rule: "No routing controls can be On."
```

`inverted` negates the *entire* assertion, not just ATLEAST→ATMOST: `threshold=1, inverted=true` evaluates as "NOT(at least 1 On)" = "zero On," blocking every control from ever being turned on. The correct config for "at most 1 On" is `threshold=2, inverted=true` ("fewer than 2 On"). Fixed in the module. The in-place `terraform apply` of that fix then hit a separate AWS provider bug (`UpdateSafetyRule` API rejecting the request for missing `Name`/`WaitPeriodMs` that the provider didn't resend on an update); worked around with `terraform apply -replace` since safety rules are free to recreate.

**Live verification after the fix**, via the ARC data-plane API (`route53-recovery-cluster`, not the control-plane API — found the correct regional data-plane endpoint via `describe-cluster`'s `ClusterEndpoints`, since the generic regional endpoint doesn't resolve):

- Set primary to `On` (dr stayed `Off`) — succeeded, matching the required initial state.
- Attempted to set `dr` to `On` while `primary` was already `On` — rejected: `"No more than 1 routing control can be On."`
- Attempted to set `primary` to `Off` while `dr` was `Off` — rejected: `"At least 1 routing control must be On."`

Both safety rules confirmed working exactly as designed, with AWS's own error text as evidence.

**DNS/traffic verification:**
```
$ dig A status.sentinel.sagaruprety.com.np +short
3.66.145.183
3.74.120.110
$ dig sentinel-aws-dr-prod-alb-....eu-central-1.elb.amazonaws.com +short
3.74.120.110
3.66.145.183
$ curl -o /dev/null -w '%{http_code}' http://status.sentinel.sagaruprety.com.np/healthz
200
```
The resolved IPs are exactly prod's ALB IPs (not DR's), confirming the ARC-gated record is routing correctly while `primary` is On.

**Update:** toggling `dr` On and confirming traffic reaches it is no longer deferred — see the Failover Rehearsal section below, where it's done for real as part of the full drill.

## PITR Restore Drill

Executed with explicit project-owner go-ahead. Source: the automated backup replica in eu-west-1 (`ab-oxkyewtltulpm57usigyokyj2oqfpwbr62f6bhc5kekifuzojvxlhpr54lz6gyp2`), restored via `restore-db-instance-to-point-in-time --use-latest-restorable-time` into a new, isolated instance (`sentinel-aws-dr-prod-pitr-test`) — not into any instance the environments manage.

The restored instance needed real connectivity to verify data, and no compute already existed inside DR's private subnets to reach it from. Rather than stand up a bastion, used temporary throwaway networking: a new public-subnet DB subnet group and a security group scoped to my one IP on 5432, both deleted immediately after. Password read from the existing SSM parameter (`--with-decryption`) rather than anything stored locally — the plaintext was never persisted anywhere by Terraform's write-only credential flow, and this was the same mechanism used to originally set it.

**Sequence:**
1. Marked the corruption point: `2026-07-17T15:58:42Z`, alongside a live read of prod's `/status` at that moment as the "last known good" reference.
2. Restore start: `15:59:35Z`. Available: `16:11:46Z`. **Restore duration: 12m11s.**
3. Connected via `docker run postgres:18-alpine psql` (psql not installed locally) to the restored instance. `SELECT target_url, checked_at FROM checks ORDER BY checked_at DESC LIMIT 5` returned real rows, newest at `15:46:42.876577Z` — confirming known pre-corruption-point data survived the restore.
4. **Observed PITR RPO: corruption point (15:58:42) − newest restored row (15:46:42.876577) ≈ 11m59s.** Consistent with AWS's own `LatestRestorableTime` for that backup (`15:46:50Z`) at the moment of restore. Section 4.3 sets no fixed PITR RPO target — the plan is explicit that this gap should be measured, not assumed — so this is reported as-measured, not against a target.
5. Deleted the temp instance (`--skip-final-snapshot`), then the temp subnet group and security group. Confirmed all three gone: `DescribeDBInstances` → `DBInstanceNotFound`, `DescribeDBSubnetGroups` → `DBSubnetGroupNotFoundFault`, `DescribeSecurityGroups` → `InvalidGroup.NotFound`.

## Failover Rehearsal (Real, Irreversible)

Executed with explicit project-owner go-ahead — this is not a dry run. Full timeline against `drill-events.log`:

| Event | Timestamp |
|---|---|
| `disaster_declared` (prod ECS scaled to 0) | 16:17:18Z |
| `failover_invoked` | 16:17:51Z |
| `replica_promoted` | 16:17:53Z |
| `dr_service_stable` / `dr_write_verified` | 16:26:43Z |
| `traffic_switched` (ARC toggle confirmed live) | 16:29:34Z |

**End-to-end RTO: 736s (12m16s)** against the 30-minute target. **Operator-invocation automation duration** (`failover_invoked`→`dr_write_verified`): **532s (8m52s)**.

**Real bug hit and fixed mid-rehearsal.** `failover.sh`'s jq render of the DR task definition unconditionally included `taskRoleArn` even when null (the app task has only an execution role, no task role — unlike the monitoring module's Grafana task, which does have one). `register-task-definition` rejects a literal `null` for a string-typed field:
```
ParamValidation: Invalid type for parameter taskRoleArn, value: None, type: <class 'NoneType'>
```
By the time this surfaced, **the replica had already been promoted** — irreversible, and not something to retry. Fixed the script (`| with_entries(select(.value != null))`) and continued the rehearsal manually from the already-completed promotion: registered the corrected task definition, scaled DR to `desired_count=2`, waited for service stability, confirmed both targets `healthy`, confirmed fresh writes via `/status`.

**Outage confirmed real before invoking failover**, not assumed: prod's ALB briefly still returned `200` right after scale-to-0 (ALB `deregistration_delay=30`), then a fresh request (`Connection: close`) returned `503` once targets fully drained — checked target health directly (`draining` / `Target.DeregistrationInProgress`) to be sure before treating the outage as real.

**ARC traffic switch**, done as a single atomic call rather than two sequential ones specifically to avoid transiting an invalid intermediate state:
```
aws route53-recovery-cluster update-routing-control-states \
  --update-routing-control-state-entries \
    "RoutingControlArn=<primary>,RoutingControlState=Off" \
    "RoutingControlArn=<dr>,RoutingControlState=On"
```
Route53's `HealthCheckStatus` CloudWatch metric (namespace `AWS/Route53`, region `us-east-1` — Route53 health check metrics are global) took about a minute to flip after the API call returned (primary 1→0, dr 0→1 between the 18:27 and 18:28 datapoints). `dig` against a Route53 nameserver directly then returned DR's exact ALB IPs, and `curl http://status.sentinel.sagaruprety.com.np/healthz` returned `200` served by DR. `GetHealthCheckStatus` doesn't work for `RECOVERY_CONTROL`-type checks (`InvalidInput: ... can't return the health of calculated health checks` — has to be CloudWatch).

**RPO, honestly reported as two different numbers because `measure.sh`'s method has a real limitation.** The script computes RPO from the newest row DR is currently serving vs. `disaster_declared` — but by the time it was run (minutes after DR started serving traffic), DR had already resumed writing fresh checks, so the "newest row" reflects DR's own new data, not the promotion-time boundary. Its output (`RPO ~0s`, DR "fully caught up") is true but not the number that matters here. The number that matters — replica lag at the moment of promotion — was already measured continuously all session at **10-17s**, well under the 60s target. `measure.sh` also had a real bug independent of this limitation: `to_epoch` choked on fractional-second timestamps from Postgres (`date: illegal option -- d` — the BSD/GNU fallback logic was broken on both branches at once for that input). Fixed (strip trailing `Z` and fractional seconds before parsing) and verified against both a fractional and non-fractional timestamp.

**Drift, confirmed visible as required:** `terraform plan` in `environments/dr` after the drill showed `desired_count` wanting to revert 2→0, the task definition revision wanting to revert 2→1, and the promoted RDS instance showing Terraform wanting to re-assert `replicate_source_db` (which would attempt to recreate it as a replica if applied blindly). Not applied — this is evidence to observe, not something to reconcile by blindly running `apply`.

**Monitoring verified meaningful on both sides during activation**, not just "alarms exist": DR's five alarms (`alb-5xx`, `alb-healthy-hosts`, `ecs-running-tasks`, `rds-cpu`, `rds-free-storage`) all read `OK`. Prod's alarms correctly flipped to `ALARM` on exactly `alb-healthy-hosts` and `ecs-running-tasks` — the two signals that should trip for this specific failure — while `rds-cpu`/`rds-free-storage`/`alb-5xx` stayed `OK` (the outage was zero targets, not errors or DB load).

## Multi-AZ Conversion (Post-Recovery Hardening)

`aws rds modify-db-instance --multi-az --apply-immediately` on the promoted (now standalone) DR instance. Start: `16:31:56Z`. `MultiAZ` flag flipped to `true` while status was still `configuring-enhanced-monitoring`; fully `available` at `16:40:15Z`, secondary AZ `eu-west-1b`. **Conversion window: 8m19s**, reported separately from the 736s RTO above — this is hardening applied after recovery was already measured complete, not part of the recovery path itself.

## A Real Directory-Context Near-Miss

While iterating on the module above, a `cd`-and-run split across two separate tool calls left the working directory silently reset to `environments/prod` for one `terraform plan`. Because that plan ran with no `-var` flags in the prod directory, it defaulted `deploy_service=false` and would have destroyed prod's real running ECS task definition and service if applied. Caught at the plan-review step before running `apply` — nothing was touched, re-confirmed with a clean `terraform plan` showing no drift in prod immediately after. Fix going forward: bind `cd` and every terraform command to the same tool call, never split them across calls and rely on persisted shell state.

## Failback: Started, Stopped Mid-Way, Then Everything Torn Down

The reverse-replication leg of the safe failback path (`docs/runbook-failover.md`) was executed for real:

1. `scripts/failback.sh snapshot` — snapshotted the stale prod instance (`sentinel-aws-dr-prod-pre-failback-20260717164020`) before touching it. Confirmed `available`.
2. Edited `environments/prod/main.tf`: `module.rds` gained `replicate_source_db_arn` pointing at DR's promoted instance ARN and a `kms_key_id` from eu-central-1's `alias/aws/rds` key — the exact mirror of the pattern DR's module already used against prod. Plan showed 3 add / 1 change / 3 destroy (old prod instance destroyed, replaced by a replica of DR, task definition and automated-backups-replication replaced since they depend on the instance). Confirmed with the project owner before applying given it destroys a real database — approved.
3. **Real race condition hit on the first apply attempt.** Terraform destroyed the old prod instance and started creating the new replica *in the same apply*, but both used the identical AWS-side `identifier` ("sentinel-aws-dr-prod") — different Terraform resource addresses (`aws_db_instance.main[0]` vs `aws_db_instance.replica[0]`), same real-world name. The create fired before the destroy had fully completed: `DBInstanceAlreadyExists`. Terraform has no way to know these two addresses collide on identity; there's no `depends_on` between a resource being destroyed and a different resource being created that happens to reuse its name. Confirmed via `describe-db-instances` → `DBInstanceNotFound` that the destroy had, in fact, finished by the time the error surfaced — simply retried the same plan/apply and it succeeded cleanly (0 destroys the second time, since the conflicting old resource was already gone from AWS and never made it into state).
4. **Second real bug: replicas don't inherit `backup_retention_period`.** The new prod replica came up with retention `0` (confirmed via `describe-db-instances`), and creating `aws_db_instance_automated_backups_replication` against it failed: `InvalidDBInstanceState: Source DB instance must have backup retention enabled`. The `rds` module's `replica` resource block had never set `backup_retention_period` at all (only the standalone `main` resource had). Fixed by adding `backup_retention_period = 7` to the replica resource — this also affected DR's own resource under the same module code, correcting its retention from AWS's default of `1` to the intended `7`.
5. Replica created (21m53s — consistent with the other cross-region replica builds this session), backup retention fixed, automated-backups-replication created successfully on retry.

**Stopped here, by explicit project-owner instruction, not by a blocker.** The remaining steps — verify the reverse replica caught up with a known row, promote prod back to standalone primary, rebuild DR as a fresh replica of the re-promoted prod, scale DR back to 0, toggle ARC back to primary-On/dr-Off — were not executed. The project owner asked to stop after the in-flight apply landed and tear down instead, to resume in a future session.

## End-of-Session Teardown

At the point of teardown, the real topology was: **DR was primary** (promoted during the rehearsal, serving live traffic, Multi-AZ), **prod was a replica of DR** (the reverse-replication leg above, just completed). This is the *opposite* of the normal direction, and it changes which side has to be destroyed first — RDS refuses to delete a source instance that still has an active replica, so the replica (prod, in this state) has to go before the source (DR).

Before destroying, reverted `environments/prod/main.tf`'s `module.rds` block back to a standalone configuration (removed `replicate_source_db_arn` / `kms_key_id`, which pointed at DR's ARN) — left as-is, a from-zero `terraform apply` next session would try to recreate prod as a replica of an ARN that no longer exists and fail immediately.

Destroy order executed: `environments/prod` first, then `environments/dr`, because prod was the replica of DR at that moment. Destroy timings and Cost Explorer results were not retained; M6 records both after its final teardown.

**What this means for next session:** this is not a resume-in-place. DR was destroyed along with prod, so the half-finished failback state (prod configured as DR's replica) doesn't carry forward — there's no DR left for it to replicate from. Next session starts by re-applying prod from zero (same M2 two-phase sequence) and DR from zero (same sequence as the start of this session), then re-running the topology-reset sequence documented above to actually reach the M5-ready end state this session stopped short of.
