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

The cutover lag gate targets `FAILBACK_CUTOVER_LAG_SECONDS` (default 60s) for up to 10 minutes; if it's still exceeded, set the var to the accepted seconds and rerun `promote-primary` (recorded as `failback_cutover_lag_seconds`).

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

## 6. Remove ARC after the drill

Revert `create_arc` to `false` in `config.json`, then apply terraform.yml `target=arc` (removes the failover pair) followed by `target=primary` (restores the plain workload record)

Note: The url shortener hostname does not resolve for up to a minute between the two applies, per the zone's 60-second negative-cache TTL.

Confirm the cluster is gone:

```bash
aws route53-recovery-control-config list-clusters --region us-west-2
```

## Credential reconciliation

A promoted replica inherits the password of the instance it replicated from, which the primary's tasks do not have. The `promote-primary` step resets it against the canonical SSM secret immediately after the Multi-AZ conversion and before compute starts, so there is no separate credential repair step.
