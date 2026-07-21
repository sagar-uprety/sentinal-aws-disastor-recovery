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

Expected: ALB continues serving through another task. The script continuously probes public `/healthz`, requires ECS to recover to two healthy targets across two AZs, verifies the stopped task ARN is absent, records recovery seconds, and records `ha_task_replacement_verified`. Retain the topology view showing replacement task IDs and `HA ready`.

## AZ Application Capacity

```bash
CONFIRM_HA=YES scripts/simulate-ha.sh az eu-central-1a
```

Expected: only tasks currently placed in that AZ stop. This is controlled application-capacity loss, not a complete AWS AZ outage. The script refuses the injection unless a task exists in another AZ, continuously probes public `/healthz`, and requires final two-target, two-AZ placement before recording recovery seconds and `ha_az_recovery_verified`.

## RDS Multi-AZ Failover

```bash
CONFIRM_HA=YES scripts/simulate-ha.sh db
```

Expected: `/healthz` can become unavailable briefly during failover. The script verifies Multi-AZ, records writer and standby AZs, samples public health every five seconds, requires RDS and public health to recover, requires the writer AZ to change, and records recovery seconds plus interruption samples. The topology card shows the writer and managed standby zones exchanged.

## Do Not Confuse With DR

These drills retain prod Region control plane and data. They do not prove regional recovery. Regional pilot-light rehearsal uses `simulate-disaster.sh`, `failover.sh`, and the separately confirmed `switch-traffic.sh dr` gate.
