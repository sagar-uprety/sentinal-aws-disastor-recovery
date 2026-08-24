# Failback to the Primary Region

This runbook returns operation to the primary Region after a failover, then restores the resting pilot-light topology.

Start here only once [`runbook-failover.md`](runbook-failover.md) is complete and the secondary is serving verified traffic.

Failback is planned work, so there is no time pressure and the safest order is the slow one. It involves two approval-gated GitHub Actions workflows alongside the drill scripts, because rebuilding a replication relationship is a structural Terraform change, not a runtime toggle.

## Preconditions

- The secondary is serving public traffic and the drill recorded `traffic_verified_secondary`.
- The primary Region is healthy again and its resources are reachable.
- ARC routing controls are still provisioned from the failover.
- The same `DRILL_LOG` from the failover is in use, since every step reads evidence the failover recorded.

Workflow dispatches below use the [GitHub CLI](https://cli.github.com). Without it, run the same workflows from the repository's **Actions** tab using **Run workflow**, supplying the inputs shown in each `-f` flag.

## Why the primary cannot simply resume

Once the secondary accepts writes it holds data the primary never saw. The primary cannot be switched back on, because doing so would serve stale data and strand every write made during the outage. RDS has no operation that converts a standalone instance into a replica in place, so the primary is destroyed and recreated as a replica of the secondary, allowed to catch up, and only then promoted back.

Across a full cycle both database instances are replaced exactly once, so the first step takes a snapshot.

## Procedure

### 1. Snapshot the active writer

```bash
CONFIRM_FAILBACK_SNAPSHOT=YES DRILL_LOG=./drill-events.log scripts/drills/failback.sh snapshot
```

This captures every post-outage write while the secondary still serves traffic, before anything replaces the primary.

The step prints the snapshot identifier and records it as `secondary_pre_failback_snapshot` in the drill log. Step 2 needs that exact value:

```bash
grep secondary_pre_failback_snapshot ./drill-events.log | tail -1
```

### 2. Rebuild the primary as a replica

```bash
gh workflow run recovery.yml --ref main \
  -f operation=failback-prepare \
  -f confirm=true \
  -f failback_snapshot_id=<snapshot-id>
```

The workflow validates the snapshot and the promoted writer, saves a plan, and applies that exact plan in a dependent job behind a protected environment approval. It destroys and recreates the primary instance as a read replica of the secondary, because RDS has no operation that converts a standalone instance into a replica in place.

The primary stays at zero tasks throughout. The application runs `CREATE TABLE IF NOT EXISTS` on start, which a read-only replica rejects, so no task can run until promotion completes.

### 3. Run the cutover

```bash
CONFIRM_FAILBACK_CUTOVER=YES DRILL_LOG=./drill-events.log scripts/drills/failback.sh cutover
```

This chains four steps: verify the primary is a current replica, freeze writes by scaling the secondary to zero, promote the primary, and confirm readiness. Between the freeze and the promote it converts the primary to Multi-AZ, reconciles the database password against the canonical SSM secret, and starts two tasks across two Availability Zones. The secondary and primary are never independent active writers.

Because writes are frozen first, the cutover lag gate requires replication to drain fully to `ReplicaLag = 0`, rather than the 300 second `FAILBACK_LAG_TARGET_SECONDS` used by the pre-freeze and post-reset checks. Any lag accepted at this point is data written on the secondary that never reached the primary, and `promote-read-replica` makes that loss permanent. The gate polls for up to 10 minutes while the workload is offline. If replication cannot reach zero and proceeding with known loss is the right call, set `FAILBACK_CUTOVER_LAG_SECONDS` to the number of seconds being accepted and rerun `promote-primary`. The accepted value is recorded as `failback_cutover_lag_seconds`.

Each step keeps its own guards and stops the chain on the first unmet condition. To resume after a failure, rerun the step that failed with its own confirmation variable and continue:

```bash
DRILL_LOG=./drill-events.log scripts/drills/failback.sh verify-replica
CONFIRM_FAILBACK_FREEZE=YES DRILL_LOG=./drill-events.log scripts/drills/failback.sh freeze-writes
CONFIRM_PRIMARY_PROMOTION=YES DRILL_LOG=./drill-events.log scripts/drills/failback.sh promote-primary
CONFIRM_FAILBACK_READY=YES DRILL_LOG=./drill-events.log scripts/drills/failback.sh ready
```

### 4. Return traffic

```bash
CONFIRM_TRAFFIC_SWITCH=primary DRILL_LOG=./drill-events.log scripts/drills/switch-traffic.sh primary
```

Then confirm both the primary-created and secondary-created links are readable through the public workload URL.

### 5. Restore the resting topology

```bash
gh workflow run recovery.yml --ref main \
  -f operation=failback-reset \
  -f confirm=true
```

This applies two saved plans. The primary plan carries no `-replace` and no replication source: it reconciles Terraform state with the promotion, Multi-AZ conversion, and scale-up the drill scripts performed through the CLI, so subsequent routine applies behave normally. The secondary plan rebuilds that instance as a replica of the restored primary and holds ECS at zero.

```bash
CONFIRM_FAILBACK_FINALIZE=YES DRILL_LOG=./drill-events.log scripts/drills/failback.sh finalize
```

`finalize` confirms the secondary is an at-rest replica with fresh lag evidence, then deletes this drill's recorded rollback snapshot. To run those separately, use `failback.sh verify-reset` followed by `CONFIRM_DELETE_SNAPSHOT=YES failback.sh delete-snapshot <snapshot-id>`.

Treat the reset as complete only once `topology_reset_verified` exists and a Terraform plan shows the intended primary-to-secondary topology. A second drill should wait for that gate.

## Credential reconciliation

A promoted replica inherits the password of the instance it replicated from, which the primary's tasks do not have. The `promote-primary` step resets it against the canonical SSM secret immediately after the Multi-AZ conversion and before compute starts, so there is no separate credential repair step.

A mismatch produced outside this flow, such as an out-of-band promotion through the console, has no scripted recovery. It requires investigation and a manual `aws rds modify-db-instance --master-user-password` against the SSM-stored value.

## Verifying standby state

The public website cannot show secondary desired count or replication direction after the reset. Confirm those through the workflow output, the AWS APIs, and `failback.sh verify-reset`.

## Abandoning a failback

Nothing in this repository restores the safety snapshot automatically. `recovery.yml` proves it exists before allowing `failback-prepare` to replace the primary, because that operation leaves the secondary as the only copy of every post-outage write. Recovery from a failed failback is a manual decision, and what to do depends on how far it got.

**Before `freeze-writes`.** Nothing destructive has happened and traffic never moved. Stop. The primary may already be a replica of the secondary, which is harmless and is redone by the next `failback-prepare`.

**After `freeze-writes`, before `promote-primary`.** The secondary database is untouched and still the writer, and only its compute is at zero. Restore service by scaling it back up. The snapshot is not needed.

```bash
aws ecs update-service --region <secondary-region> \
  --cluster <project>-secondary --service <project>-secondary --desired-count 2
```

**After `promote-primary`.** The primary is a standalone writer and replication is severed, but the secondary still holds the data it had at the freeze. Scaling the secondary back up recovers service. Leave traffic where it is, and note that two independent writers now exist, so one has to be abandoned. The snapshot is still not needed.

**After `failback-reset`.** The secondary has been rebuilt as a replica of the primary, so its post-outage copy is gone. This is the case the snapshot exists for. Restore it under a new identifier so nothing in Terraform state is overwritten and the contents can be inspected first:

```bash
aws rds restore-db-instance-from-db-snapshot \
  --region <secondary-region> \
  --db-instance-identifier <project>-secondary-rollback \
  --db-snapshot-identifier <snapshot-id>
```

The restored instance sits outside Terraform state. Treat it as a source to reconcile data from, then delete it by hand instead of importing it.

Since `finalize` deletes the snapshot, run it only once the restored topology is trusted. Until then it is the only remaining copy of the post-outage writes.

## Remove ARC after the drill

Revert `create_arc` to `false`, merge, and apply `target=secondary` again. `recovery.yml` never passes `-var=create_arc`, so it leaves whatever the committed tfvars says. Confirm the cluster is gone:

```bash
aws route53-recovery-control-config list-clusters --region us-west-2
```
