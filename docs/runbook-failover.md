# Regional Failover

This runbook takes the primary Region out of service, activates the secondary, and moves public traffic to it.

It covers the outbound half of the cycle only. Returning to the primary Region is a separate, planned operation documented in [`runbook-failback.md`](runbook-failback.md). Complete that before treating a drill as finished.

In-region drills that stay within `eu-central-1` are covered in [`runbook-ha.md`](runbook-ha.md).

The secondary Region already holds the database replica, VPC, ALB, ECS service definition, container image, and SSM parameters. Only the ECS desired count is zero. ARC routing controls are the exception: they bill per cluster-hour, so they are provisioned for a drill and removed once the failback is complete.

## Preconditions

- The workload serves `https://shortener.pilotlight.sagaruprety.com.np` with two healthy ECS targets.
- The secondary RDS instance is an available read replica of the primary, and secondary ECS desired count is zero.
- The immutable image digest exists in the `eu-west-1` ECR repository.
- Regional SSM SecureString parameters for the database password and link-creation token are current in both Regions.
- Sentry is serving from `eu-north-1` on its own state and infrastructure.
- The GitHub repository variables listed in the README's [Configure](../README.md#configure) section are set, and the protected environments that gate the jobs consuming them exist.
- Local AWS credentials permit the ECS, RDS, ELB, ECR, SSM, CloudWatch, Route 53, and ARC calls the drill scripts make. This project does not provision a separate local recovery role.

Use a dedicated `DRILL_LOG` path for the session. Each simulation writes a new `drill_started` boundary, and later steps read back only to that marker, so measurements from separate drills stay separate.

Workflow dispatches below use the [GitHub CLI](https://cli.github.com). Without it, run the same workflows from the repository's **Actions** tab using **Run workflow**, supplying the inputs shown in each `-f` flag.

## Provision ARC

ARC lives in its own `arc` environment, independent of primary and secondary, since it needs both ALBs and neither region owns it. Provisioning it retracts primary's plain workload record first, then creates the ARC failover pair, since Route53 rejects a plain record alongside a same-name failover pair. The hostname does not resolve for the few seconds between the two applies.

Set `create_arc: true` in `config.json`, merge it, then apply primary followed by arc, in that order:

```bash
gh workflow run terraform.yml --ref main -f operation=apply -f target=primary
```

```bash
gh workflow run terraform.yml --ref main -f operation=apply -f target=arc
```

Initialize the routing controls to their resting state:

```bash
CONFIRM_TRAFFIC_SWITCH=INITIALIZE DRILL_LOG=./drill-events.log scripts/drills/switch-traffic.sh initialize
```

This sets primary `On` and secondary `Off`. The ARC safety rule requires exactly one active control.

## Failover

### 1. Inject and confirm the outage

```bash
CONFIRM_DISASTER=YES DRILL_LOG=./drill-events.log scripts/drills/simulate-disaster.sh
```

The script verifies the pilot-light prerequisites, creates a short link on the primary and records its slug along with the full set of existing slugs, then scales primary ECS to zero. It records `outage_confirmed` only once the ALB returns HTTP 503 with zero healthy targets, using both signals so a transient error is not mistaken for the outage. If it cannot prove the outage within two minutes it restores the original desired count and exits non-zero.

### 2. Promote and activate the secondary

```bash
CONFIRM_FAILOVER=YES DRILL_LOG=./drill-events.log scripts/drills/failover.sh
```

Before promoting, the script validates the replica, confirms the image digest is immutable and present in the secondary ECR, checks both regional SSM parameters resolve, and requires fresh CloudWatch `ReplicaLag` evidence within the RPO target.

It then promotes the replica, registers a task definition pointing at the promoted endpoint, scales to two tasks across two Availability Zones, waits for two healthy ALB targets, confirms every pre-outage link is present, and creates a new link to prove the promoted database accepts writes.

Traffic does not move in this step.

### 3. Switch traffic

```bash
CONFIRM_TRAFFIC_SWITCH=secondary DRILL_LOG=./drill-events.log scripts/drills/switch-traffic.sh secondary
```

The script resolves the ARC cluster and routing controls, confirms the current state is primary `On` and secondary `Off`, then sends both state changes in a single atomic `update-routing-control-states` call through the first responsive regional data-plane endpoint. It reads the state back instead of trusting the call, then polls for up to three minutes until authoritative Route 53 DNS, the public health endpoint, and the expected link all confirm the secondary is serving.

This drill resolves ARC identifiers through control-plane APIs immediately before switching. A production runbook should hold the five data-plane endpoints and control ARNs out of band, since the control plane is the less available of the two.

### 4. Print measurements

```bash
DRILL_LOG=./drill-events.log scripts/drills/measure.sh
```

RTO runs from `outage_confirmed` to `traffic_verified`. The report also breaks out the declaration, detection, promotion, task startup, target health, write verification, and routing phases.

### 5. Harden the promoted database

Promotion produces a single-AZ writer. Converting it back to Multi-AZ happens after service is restored and is excluded from RTO.

```bash
source scripts/config.sh
aws rds modify-db-instance \
  --region "$SECONDARY_REGION" \
  --db-instance-identifier "$SECONDARY_RESOURCE_NAME" \
  --multi-az \
  --apply-immediately
aws rds wait db-instance-available \
  --region "$SECONDARY_REGION" \
  --db-instance-identifier "$SECONDARY_RESOURCE_NAME"
```

## Measurement

The RPO target for replica promotion is 60 seconds.

`failover.sh` records the newest CloudWatch `ReplicaLag` maximum before promoting. AWS reports `ReplicaLag = 0` as synchronized and `-1` when replication is inactive or undeterminable, so the script treats `-1` and stale datapoints as absent evidence rather than as zero lag. Promotion is refused when evidence is missing, older than 180 seconds, or above the target, unless `ALLOW_RPO_TARGET_MISS=YES` is set to accept and record a deliberate miss.

Link survival provides application-level evidence alongside the control-plane measurement. `simulate-disaster.sh` records every slug present on the primary before the outage, and `failover.sh` requires every one of them after promotion, not a sample. A link created on the secondary afterwards proves the promoted instance accepts writes, and failback requires that same link on the primary before returning traffic.

Reference result from a live drill on 2026-08-08: end-to-end RTO 666 seconds against the 30 minute target, RPO 26.0 seconds of measured `ReplicaLag` against the 60 second target, with every pre-outage link verified present after promotion.

## Logical corruption

Replica promotion is the wrong response to logical corruption, because replication copies the corrupted data to the secondary faithfully. Use the cross-Region automated backup instead: restore to a point in time into an isolated instance, validate known data, and record the restore point and duration. A measured isolated restore took 12 minutes 11 seconds, which is a reference figure, not a guarantee.

## Emergency Route 53 fallback

If the ARC data-plane endpoints are unavailable, a deliberate Route 53 record update can move traffic after the same readiness checks. This path uses the Route 53 control plane, has no ARC safety-rule protection, and has not been exercised. Treat it as a last resort, not an equivalent to the verified ARC path.

## Next

Once the secondary is serving and the measurements are recorded, continue with [`runbook-failback.md`](runbook-failback.md). Leaving the workload on the secondary indefinitely means running with a diverged primary and no standby.
