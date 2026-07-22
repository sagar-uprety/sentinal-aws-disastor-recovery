# In-Region HA Drill Runbook

This runbook tests primary-region high availability. It is separate from pilot-light disaster recovery and must not invoke replica promotion or ARC routing controls.

## Preconditions

- Prod deployed with `multi_az=true` and two healthy Sentinel tasks.
- Open the status page and record the Recovery topology before each drill. The ECS card must show `2 / 2 running`, two Availability Zones, and `HA ready`.
- Use `CONFIRM_HA=YES` only during an approved drill.

## Task Replacement

```bash
CONFIRM_HA=YES scripts/simulate-ha.sh task
```

Expected: ALB continues serving through another task. Keep the website open during the injection and retain the Recovery topology before and after the script. Verify the stopped task ID disappears, a replacement task ID appears, compute returns to `2 / 2 running` across two AZs, and `HA ready` returns. The serving-task card identifies the task and AZ that answered each sampled page request. The script continuously probes public `/healthz`, requires ECS to recover to two healthy targets across two AZs, verifies the stopped task ARN is absent, records recovery seconds, and records `ha_task_replacement_verified`.

## AZ Application Capacity

```bash
CONFIRM_HA=YES scripts/simulate-ha.sh az eu-central-1a
```

Expected: only tasks currently placed in that AZ stop. Keep the website open and retain Recovery topology during the reduced-capacity interval when observable, showing requests served by a surviving task outside the injected AZ. After recovery, verify new task IDs, `2 / 2 running`, two-AZ spread, and `HA ready`. Because ALB may serve either healthy task after recovery, use task IDs and compute spread rather than requiring every later page refresh to come from one AZ. This is controlled application-capacity loss, not a complete AWS AZ outage. The script refuses the injection unless a task exists in another AZ, continuously probes public `/healthz`, and requires final two-target, two-AZ placement before recording recovery seconds and `ha_az_recovery_verified`.

## RDS Multi-AZ Failover

```bash
CONFIRM_HA=YES scripts/simulate-ha.sh db
```

Expected: `/healthz` can become unavailable briefly during failover. Retain Recovery topology before and after the script, showing the database writer and managed-standby AZs exchanged, status `available`, and the application still in eu-central-1. The script verifies Multi-AZ, retains a known database row, records writer and standby AZs, samples public health every five seconds, requires RDS and public health to recover, requires the writer AZ to change, verifies the known row still exists, and records recovery seconds plus interruption samples.

## Do Not Confuse With DR

These drills retain prod Region control plane and data. They do not prove regional recovery. Regional pilot-light rehearsal uses `simulate-disaster.sh`, `failover.sh`, and the separately confirmed `switch-traffic.sh dr` gate.
