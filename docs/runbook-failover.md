# Failover Runbook

AWS defines pilot light as replicated data plus core infrastructure in a standby Region, with additional compute activated during recovery. Pilotlight follows that model for the URL-shortener workload: eu-west-1 database replica, workload VPC, ALB, ECS service definition, ECR image, and SSM parameters exist before drill, while workload ECS desired count remains 0. Isolated sentry uses separate state and infrastructure and remains outside workload operations. ARC routing controls are provisioned on demand via `create_arc=true` to avoid idle cost.

Historical scripts completed a live M6 drill on 2026-07-22 against the former coupled architecture; those measurements remain historical and are not conflated with M7 below. M7's isolated two-plane architecture completed its own full live drill on 2026-08-08 (see Measurement Semantics).

## Preconditions

- Isolated sentry serves `https://sentry.pilotlight.sagaruprety.com.np` from separate eu-north-1 state, VPC, ECS service, ALB, ECR repository, and DynamoDB table.
- Primary workload serves `https://shortener.pilotlight.sagaruprety.com.np` with two healthy ECS targets; `/healthz` verifies PostgreSQL readiness.
- Secondary RDS is an available read replica and secondary ECS desired count is 0.
- The immutable image digest exists in eu-west-1 ECR.
- Regional database-password and link-creation-token SSM SecureString metadata and versions are current. Terraform generates both secrets through ephemeral values and write-only arguments.
- GitHub repository variables define `AWS_TERRAFORM_ROLE_ARN`, `AWS_WORKLOAD_ROLE_ARN`, and `AWS_SENTRY_ROLE_ARN`; protected environments gate the jobs that consume them.
- **Before a drill, provision ARC** through CI:
  ```bash
  gh workflow run terraform.yml --ref main -f operation=apply -f target=secondary -f create_arc=true
  ```
  Then initialize controls:
  ```bash
  CONFIRM_TRAFFIC_SWITCH=INITIALIZE DRILL_LOG=./drill-events.log scripts/drills/switch-traffic.sh initialize
  ```
  ARC controls must be primary `On`, secondary `Off`; safety rules require exactly one active control.
- Use a dedicated `DRILL_LOG` path for the session. Each simulation adds a new `drill_started` boundary so measurements cannot mix drills.
- Local scripts assume the active AWS CLI credentials already permit their ECS, RDS, ELB, ECR, SSM, CloudWatch, Route53, ARC, and sentry-table DynamoDB operations. This project does not provision a separate local recovery role.
- **After drill, tear down ARC** to save cost: `gh workflow run terraform.yml --ref main -f operation=apply -f target=secondary -f create_arc=false`. In practice this often happens automatically: any later `recovery.yml` apply against the secondary root runs with default variables (`create_arc=false`), so the first failback apply after a drill will destroy ARC as a side effect even without this explicit step. Confirm actual state either way with `aws route53-recovery-control-config list-clusters --region us-west-2`.

## Drill Sequence

1. Start and confirm the controlled outage:

   ```bash
   CONFIRM_DISASTER=YES DRILL_LOG=./drill-events.log scripts/drills/simulate-disaster.sh
   ```

   Script verifies pilot-light prerequisites, creates and records a normal short link in primary, scales primary ECS to 0, and records `outage_confirmed` only after workload ALB returns 503 with zero healthy targets. It also requires sentry health and restores original desired count if confirmation fails.

2. Independently review `drill-events.log`, primary target health, and user impact. Promotion is irreversible.

3. Promote and activate secondary:

   ```bash
   CONFIRM_FAILOVER=YES DRILL_LOG=./drill-events.log scripts/drills/failover.sh
   ```

   Before promotion, script requires current outage marker, validates replica, regional immutable image, regional SSM token parameter, and fresh ReplicaLag evidence. It then promotes RDS, starts two ECS tasks across two AZs, requires two healthy ALB targets, verifies primary-created link, creates a secondary link through `POST /links`, and verifies sentry health. It does not switch traffic.

4. Switch the pre-created ARC controls as a separate operator gate:

   ```bash
   CONFIRM_TRAFFIC_SWITCH=secondary DRILL_LOG=./drill-events.log scripts/drills/switch-traffic.sh secondary
   ```

   Script discovers ARC cluster and controls, verifies primary `On` and secondary `Off`, sends both state changes in one atomic `update-routing-control-states` request through an available regional ARC data-plane endpoint, and verifies resulting states. It records completion only after authoritative Route53 DNS, workload health, and expected short link prove eu-west-1 serves `shortener.pilotlight.sagaruprety.com.np`. It separately verifies sentry health. This demo discovers identifiers through AWS control-plane APIs immediately before switching; production runbook should retain five data-plane endpoints and control ARNs out of band.

   Retain refreshed sentry topology after switch. It must show eu-west-1 workload compute and database state while sentry remains served from isolated plane.

5. Print measurements:

   ```bash
   DRILL_LOG=./drill-events.log scripts/drills/measure.sh
   ```

   RTO runs from `outage_confirmed` through `traffic_verified`. The report also prints promotion, task startup, target health, write verification, and routing phases.

6. Harden the promoted secondary database after service recovery. This is not part of RTO:

   ```bash
   aws rds modify-db-instance \
     --region eu-west-1 \
     --db-instance-identifier pilotlight-secondary \
     --multi-az \
     --apply-immediately
   aws rds wait db-instance-available \
     --region eu-west-1 \
     --db-instance-identifier pilotlight-secondary
   ```

## Measurement Semantics

Replica-promotion RPO target is 60 seconds. `simulate-disaster.sh` creates a normal primary link before outage. `failover.sh` requires that link after promotion, records its original timestamp, and creates a second link in secondary. Failback requires secondary-created link after primary promotion. Link survival is application-level evidence; fresh pre-promotion `ReplicaLag` remains supporting AWS control-plane evidence.

`failover.sh` also records the latest fresh CloudWatch `ReplicaLag` maximum before promotion. AWS documents `ReplicaLag=0` as synchronized and `-1` as inactive or unknown. The script refuses a drill promotion when evidence is missing, stale, or above 60 seconds unless the operator explicitly sets `ALLOW_RPO_TARGET_MISS=YES` to preserve and report a deliberate target miss.

Historical M6 result (former coupled architecture): user-visible outage confirmation through authoritative DNS and public secondary `/topology` verification was 538 seconds. `failover_invoked` through fresh secondary write verification was 457 seconds; invocation through public verification was 516 seconds. Row-based observed RPO was 0 seconds, with fresh pre-promotion `ReplicaLag` of 12 seconds. These values describe the former architecture and are not M7 evidence.

M7 result (isolated two-plane architecture, live 2026-08-08): end-to-end RTO (`outage_confirmed` through `traffic_verified`) was 666 seconds, against the 30-minute target. RPO was 26.0 seconds of measured CloudWatch `ReplicaLag`, against the 60-second target; every link present on primary before the outage, not a sample of one, was verified present in secondary after promotion. Full breakdown and bug findings from this drill are in drill evidence.

## Failback And Topology Reset

Once secondary accepts writes, old primary has diverged and cannot simply resume.

1. Snapshot the active secondary writer while it still serves traffic. This protects all post-failover writes before former primary is replaced:

   ```bash
   CONFIRM_FAILBACK_SNAPSHOT=YES DRILL_LOG=./drill-events.log scripts/drills/failback.sh snapshot
   ```

2. Dispatch the guarded recovery workflow. It validates the active-secondary snapshot and writer, saves the reverse-replication plan, and applies that exact plan in a dependent job:

   ```bash
   gh workflow run recovery.yml --ref main \
     -f operation=failback-prepare \
     -f confirm_failback=REBUILD_PRIMARY \
     -f failback_snapshot_id=<snapshot-id>
   ```

   Verify source and lag after the workflow succeeds:

   ```bash
   DRILL_LOG=./drill-events.log scripts/drills/failback.sh verify-replica
   ```

3. Verify primary is a fresh reverse replica. Then begin a planned failback interruption by scaling secondary compute to zero and retaining secondary-created link slug. Only after writes are frozen does script recheck fresh lag evidence, promote primary, convert it to Multi-AZ, start primary tasks, and require that secondary-created link. Secondary and primary are never independent active writers:

   ```bash
   CONFIRM_FAILBACK_FREEZE=YES DRILL_LOG=./drill-events.log scripts/drills/failback.sh freeze-writes
   CONFIRM_PRIMARY_PROMOTION=YES DRILL_LOG=./drill-events.log scripts/drills/failback.sh promote-primary
   CONFIRM_FAILBACK_READY=YES DRILL_LOG=./drill-events.log scripts/drills/failback.sh ready
   ```

4. Atomically return traffic and verify public primary service:

   ```bash
   CONFIRM_TRAFFIC_SWITCH=primary DRILL_LOG=./drill-events.log scripts/drills/switch-traffic.sh primary
   ```

   Retain refreshed sentry topology showing eu-central-1 workload compute and database state, then verify both primary-created and secondary-created links through workload URL.

5. Dispatch the guarded reset workflow. Its exact saved plans reconcile primary as standalone, rebuild secondary as primary's replica, and retain secondary ECS at desired count zero:

   ```bash
   gh workflow run recovery.yml --ref main \
     -f operation=failback-reset \
     -f confirm_failback=RESET_SECONDARY
   ```

   Verify reset after the workflow succeeds:

   ```bash
   DRILL_LOG=./drill-events.log scripts/drills/failback.sh verify-reset
   ```

6. Delete the active-secondary safety snapshot after reset evidence is retained, using the exact command printed by `failback.sh snapshot`.

Normal promotion preserves the password inherited by the replica. Terraform therefore ignores later changes to the standalone RDS resource's write-only password fields; do not increment a credential-version variable during ordinary failback. If an older reset has already produced an RDS and SSM mismatch, use the guarded break-glass workflow after verifying reset topology:

   ```bash
   gh workflow run recovery.yml --ref main \
     -f operation=credential-repair \
     -f confirm_failback=RECONCILE_CREDENTIAL
   ```

The repair reads the existing SecureString only inside the protected runner, resets the primary RDS password to that value, forces an ECS deployment, and requires healthy public `/topology`. It is recovery for an observed mismatch, not a routine failback phase or password-rotation mechanism.

The active primary website cannot display secondary desired count zero or primary-to-secondary replica direction after reset. Verify those standby-only properties through the workflow output, AWS APIs, and `failback.sh verify-reset`; do not infer them from the website.

Do not declare reset complete until `topology_reset_verified` exists and Terraform plans show the intended primary-to-secondary topology. Any optional second drill must wait for that gate.

## Corruption Alternative

Replica promotion is wrong for logical corruption because replication carries corruption to secondary. Use the cross-Region automated-backup PITR procedure instead, restore into an isolated database, validate known data, and record the restore point and duration. The real M4 isolated restore took 12m11s; this is historical evidence, not a promised duration.

## Emergency Route53 Fallback

If ARC data-plane endpoints are unavailable, a deliberate Route53 record update can move traffic after the same readiness checks. This uses the Route53 control plane, lacks ARC safety-rule protection, has not been exercised, and must not be presented as equivalent to the verified ARC path.
