# In-Region HA Drill Runbook

This runbook tests primary-region high availability. It is separate from pilot-light disaster recovery and must not invoke replica promotion or ARC routing controls.

## Preconditions

- Isolated monitor is healthy at `https://monitor.pilotlight.sagaruprety.com.np` and deployed from separate monitoring state.
- Workload is healthy at `https://shortener.pilotlight.sagaruprety.com.np`, with prod `multi_az=true` and two healthy ECS tasks.
- Open monitor and record workload topology before each drill. ECS card must show `2 / 2 running`, two Availability Zones, and `HA ready`.
- Use `CONFIRM_HA=YES` only during an approved drill.

## Task Replacement

```bash
CONFIRM_HA=YES scripts/simulate-ha.sh task
```

Expected: workload ALB continues serving through another task while monitor remains healthy. Retain monitor topology before and after script. Verify stopped workload task ID disappears, replacement task ID appears, compute returns to `2 / 2 running` across two AZs, and `HA ready` returns. Script continuously probes workload `/healthz`, requires ECS to recover to two healthy targets across two AZs, verifies stopped task ARN is absent, and records recovery evidence.

## AZ Application Capacity

```bash
CONFIRM_HA=YES scripts/simulate-ha.sh az eu-central-1a
```

Expected: only workload tasks currently placed in that AZ stop. Keep monitor open during reduced-capacity interval. After recovery, verify new workload task IDs, `2 / 2 running`, two-AZ spread, and `HA ready`. This is controlled application-capacity loss, not a complete AWS AZ outage. Script refuses injection unless a task exists in another AZ, continuously probes workload `/healthz`, requires monitor health, and requires final two-target, two-AZ placement before recording recovery evidence.

## RDS Multi-AZ Failover

```bash
CONFIRM_HA=YES CONFIRM_HA_DB_FAILOVER=YES scripts/simulate-ha.sh db
```

This forces a real Multi-AZ failover on the production database, materially higher blast radius than the task/AZ drills above, so it requires its own confirmation on top of `CONFIRM_HA`.

Expected: workload `/healthz` can become unavailable briefly during failover while monitor `/healthz` remains available. Retain monitor topology before and after script, showing workload database writer and managed-standby AZs exchanged, status `available`, and workload still in eu-central-1. Script creates a known short link, samples workload health every five seconds, requires RDS and workload health to recover, requires writer AZ to change, and verifies link still exists.

## Do Not Confuse With DR

These drills retain prod Region control plane and data. They do not prove regional recovery. Regional pilot-light rehearsal uses `simulate-disaster.sh`, `failover.sh`, and the separately confirmed `switch-traffic.sh dr` gate.
