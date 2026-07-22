# Failover Runbook

AWS defines pilot light as replicated data plus core infrastructure in a standby Region, with additional compute activated during recovery. Sentinel follows that model: the eu-west-1 database replica, VPC, ALB, ECS service definition, ECR image, SSM parameter, monitoring, and ARC controls exist before the drill, while ECS desired count remains 0.

The M4 rehearsal on 2026-07-17 used earlier script revisions. Historical measurements below remain evidence of that run. Current hardened scripts require live M6 execution before they can replace those measurements.

## Preconditions

- Primary serves the dashboard at `https://sentinel.sagaruprety.com.np` with two healthy ECS targets; `/healthz` is its machine-readable health endpoint.
- DR RDS is an available read replica and DR ECS desired count is 0.
- The immutable image digest exists in eu-west-1 ECR.
- The eu-west-1 SSM SecureString metadata and version are current.
- ARC controls are primary `On`, DR `Off`; safety rules require exactly one active control.
- Before injecting failure, run `CONFIRM_TRAFFIC_SWITCH=INITIALIZE DRILL_LOG=./drill-events.log scripts/switch-traffic.sh initialize` and verify primary `On`, DR `Off`.
- Use a dedicated `DRILL_LOG` path for the session. Each simulation adds a new `drill_started` boundary so measurements cannot mix drills.
- Local scripts assume the active AWS CLI credentials already permit their ECS, RDS, ELB, ECR, SSM, CloudWatch, Route53, and ARC operations. This project does not provision a separate local recovery role.

## Drill Sequence

1. Start and confirm the controlled outage:

   ```bash
   CONFIRM_DISASTER=YES DRILL_LOG=./drill-events.log scripts/simulate-disaster.sh
   ```

   The script verifies pilot-light prerequisites, records the newest primary row for the canonical RPO target, scales primary ECS to 0, and records `outage_confirmed` only after the primary ALB returns 503 with zero healthy targets. It restores the original desired count if confirmation fails.

2. Independently review `drill-events.log`, primary target health, and user impact. Promotion is irreversible.

3. Promote and activate DR:

   ```bash
   CONFIRM_FAILOVER=YES DRILL_LOG=./drill-events.log scripts/failover.sh
   ```

   Before promotion, the script requires the current outage marker, validates the replica, regional immutable image, regional SSM parameter, and fresh ReplicaLag evidence. It then promotes RDS, starts two ECS tasks across two AZs, requires two healthy ALB targets, verifies a fresh database write, and records the newest matching pre-outage row available in DR. It does not switch traffic.

4. Switch the pre-created ARC controls as a separate operator gate:

   ```bash
   CONFIRM_TRAFFIC_SWITCH=DR DRILL_LOG=./drill-events.log scripts/switch-traffic.sh dr
   ```

   The script discovers the ARC cluster and controls, verifies primary `On` and DR `Off`, sends both state changes in one atomic `update-routing-control-states` request through an available regional ARC data-plane endpoint, and verifies the resulting states. It records completion only after authoritative Route53 DNS and `/topology` prove eu-west-1 serves the canonical hostname. This demo discovers identifiers through AWS control-plane APIs immediately before switching; a production runbook should retain the five data-plane endpoints and control ARNs out of band.

   Retain the refreshed website Recovery topology after the switch. It must show eu-west-1 for the serving task, compute, and database; two running tasks across two AZs with `HA ready`; and the promoted DR database as available writer. During the injected outage, the canonical website being unavailable is expected evidence rather than a topology-rendering failure.

5. Print measurements:

   ```bash
   DRILL_LOG=./drill-events.log scripts/measure.sh
   ```

   RTO runs from `outage_confirmed` through `traffic_verified`. The report also prints promotion, task startup, target health, write verification, and routing phases.

6. Harden the promoted DR database after service recovery. This is not part of RTO:

   ```bash
   aws rds modify-db-instance \
     --region eu-west-1 \
     --db-instance-identifier sentinel-aws-dr-dr \
     --multi-az \
     --apply-immediately
   aws rds wait db-instance-available \
     --region eu-west-1 \
     --db-instance-identifier sentinel-aws-dr-dr
   ```

## Measurement Semantics

The replica-promotion RPO target is 60 seconds. `simulate-disaster.sh` records the canonical target's newest primary check before the outage. After promotion, `failover.sh` reads DR history and records the newest matching row at or before `outage_confirmed`. `measure.sh` reports their difference as row-based observed RPO.

`failover.sh` also records the latest fresh CloudWatch `ReplicaLag` maximum before promotion. AWS documents `ReplicaLag=0` as synchronized and `-1` as inactive or unknown. The script refuses a drill promotion when evidence is missing, stale, or above 60 seconds unless the operator explicitly sets `ALLOW_RPO_TARGET_MISS=YES` to preserve and report a deliberate target miss.

M4 historical result: `failover_invoked` through fresh DR write verification was 532 seconds. The former 736-second disaster-to-switch number ended at a manually recorded ARC request and is retained only as historical M4 evidence. It is not the M6 RTO definition.

## Failback And Topology Reset

Once DR accepts writes, old prod has diverged and cannot simply resume.

1. Snapshot the active DR writer while it still serves traffic. This protects all post-failover writes before former prod is replaced:

   ```bash
   CONFIRM_FAILBACK_SNAPSHOT=YES DRILL_LOG=./drill-events.log scripts/failback.sh snapshot
   ```

2. Dispatch the guarded recovery workflow. It validates the active-DR snapshot and writer, saves the reverse-replication plan, and applies that exact plan in a dependent job:

   ```bash
   gh workflow run recovery.yml --ref main \
     -f operation=failback-prepare \
     -f confirm_failback=REBUILD_PROD \
     -f failback_snapshot_id=<snapshot-id>
   ```

   Verify source and lag after the workflow succeeds:

   ```bash
   DRILL_LOG=./drill-events.log scripts/failback.sh verify-replica
   ```

3. Verify prod is a fresh reverse replica. Then begin a planned failback interruption by scaling DR compute to zero and retaining the last observed DR row. Only after writes are frozen does the script recheck fresh lag evidence, promote prod, convert it to Multi-AZ, and start prod tasks. DR and prod are never independent active writers:

   ```bash
   CONFIRM_FAILBACK_FREEZE=YES DRILL_LOG=./drill-events.log scripts/failback.sh freeze-writes
   CONFIRM_PRIMARY_PROMOTION=YES DRILL_LOG=./drill-events.log scripts/failback.sh promote-primary
   CONFIRM_FAILBACK_READY=YES DRILL_LOG=./drill-events.log scripts/failback.sh ready
   ```

4. Atomically return traffic and verify public prod service:

   ```bash
   CONFIRM_TRAFFIC_SWITCH=PRIMARY DRILL_LOG=./drill-events.log scripts/switch-traffic.sh primary
   ```

   Retain the refreshed website Recovery topology showing eu-central-1 for the serving task, compute, and database; two running tasks across two AZs with `HA ready`; and the prod database as available Multi-AZ writer.

5. Dispatch the guarded reset workflow. Its exact saved plans reconcile prod as standalone, rebuild DR as prod's replica, and retain DR ECS at desired count zero:

   ```bash
   gh workflow run recovery.yml --ref main \
     -f operation=failback-reset \
     -f confirm_failback=RESET_DR
   ```

   Verify reset after the workflow succeeds:

   ```bash
   DRILL_LOG=./drill-events.log scripts/failback.sh verify-reset
   ```

6. Delete the active-DR safety snapshot after reset evidence is retained, using the exact command printed by `failback.sh snapshot`.

The active prod website cannot display DR desired count zero or primary-to-DR replica direction after reset. Verify those standby-only properties through the workflow output, AWS APIs, and `failback.sh verify-reset`; do not infer them from the website.

Do not declare reset complete until `topology_reset_verified` exists and Terraform plans show the intended primary-to-DR topology. Any optional second drill must wait for that gate.

## Corruption Alternative

Replica promotion is wrong for logical corruption because replication carries corruption to DR. Use the cross-Region automated-backup PITR procedure instead, restore into an isolated database, validate known data, and record the restore point and duration. The real M4 isolated restore took 12m11s; this is historical evidence, not a promised duration.

## Emergency Route53 Fallback

If ARC data-plane endpoints are unavailable, a deliberate Route53 record update can move traffic after the same readiness checks. This uses the Route53 control plane, lacks ARC safety-rule protection, has not been exercised, and must not be presented as equivalent to the verified ARC path.
