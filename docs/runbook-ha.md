# In-Region High Availability Drills

These drills test resilience inside the primary Region: losing a task, losing a Region's worth of capacity in one Availability Zone, and failing the database over between zones. They stay entirely within `eu-central-1`

## Preconditions

Every drill refuses to start unless all of the following hold. `simulate-ha.sh` checks them itself and exits with the observed values if any fail.

- The workload is serving at `https://shortener.pilotlight.sagaruprety.com.np`.
- The primary ECS service is at two running tasks spread across two Availability Zones.
- Both ALB targets are healthy.
- The primary database is `multi_az = true`.
- Sentry is reachable and reports the primary database as available.

## Task replacement

Stops one running task and confirms ECS replaces it without a user-visible outage.

```bash
CONFIRM_HA=YES scripts/drills/simulate-ha.sh task
```

The script records the stopped task ARN, then polls until the service returns to two running tasks across two Availability Zones with two healthy targets. It samples the public health endpoint throughout, and fails the drill if any sample returns a non-200. It also confirms the stopped task ARN is absent from the running set, so a recovered count alone does not pass.

Expected result: the service returns to two healthy tasks with a new task ARN in place of the stopped one, and public health stays at 200 for the whole window.

## Availability Zone capacity loss

Stops every task in one Availability Zone and confirms the surviving zone continues serving while ECS restores capacity.

```bash
CONFIRM_HA=YES scripts/drills/simulate-ha.sh az eu-central-1a
```

The script refuses to run unless at least one task exists outside the target zone.

Expected result: the surviving zone serves traffic throughout, and ECS restores two-zone placement with new task ARNs.

## RDS Multi-AZ failover

Forces a real failover of the primary database to its standby.

```bash
CONFIRM_HA=YES CONFIRM_HA_DB_FAILOVER=YES scripts/drills/simulate-ha.sh db
```

Before failing over, the script confirms the instance is genuinely Multi-AZ with a real standby, and creates a short link with a known slug. It then calls `reboot-db-instance --force-failover` and polls for up to 10 minutes until the instance is available and reporting a different writer Availability Zone.

Public health is sampled every five seconds and the number of failed samples is recorded. A brief interruption is expected here and does not fail the drill.

Finally the script confirms the pre-failover link is still readable. Multi-AZ replication is synchronous, so a missing row would indicate real data loss, not expected downtime.

Expected result: the writer Availability Zone changes, the instance returns to `available`, the application reconnects through the unchanged endpoint, and the known link survives.

## Evidence

Each drill appends timestamped events to `drill-events.log`, including the measured recovery duration and, for the database drill, the writer zones before and after plus the count of failed health samples.
