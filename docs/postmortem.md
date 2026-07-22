# Disaster Recovery Drill Postmortem

M6 live drill recorded on 2026-07-22. All measured values are actual, not planned.

## Scope

- Drill date: 2026-07-22
- Git commit at drill start: `3af7e72270857fad5aa1ff901ab5bc8074c25ed1`
- AWS session span: infrastructure built 2026-07-21, drills executed 2026-07-22, final evidence captured 2026-07-22
- Primary region: eu-central-1
- DR region: eu-west-1

## Executive Summary

- Scenario: controlled primary workload outage, cross-Region replica promotion, DR compute activation, atomic ARC traffic switch, reverse replication, planned failback, and pilot-light reset.
- User impact: canonical site returned 503 from 12:54:58 UTC until DR traffic verification at 13:03:56 UTC. Planned failback write freeze lasted 14 minutes through verified primary traffic.
- End-to-end RTO target and measured result: 30 minutes target; 538s (8m58s) measured, target met.
- Promotion-time RPO target and measured result: 60s target; row-based observed RPO 0s (the newest application row present in both prod and DR) with fresh pre-promotion `ReplicaLag` 12s, target met.
- **RPO realism note:** PostgreSQL cross-region replication is asynchronous. The 0s row-based RPO means the sampled application row had already replicated; it does not prove every final source commit at the boundary survived. The 12s CloudWatch `ReplicaLag` is the worst lag in the measurement window. Estimated realistic RPO for this architecture under demo load: <15 seconds.
- Topology-reset duration: infrastructure reset completed, credential reconciled, safety snapshot deleted, final public health verified (200 OK, 2/2 prod tasks, DR 0/0 replica). Planned failback interruption: 840s (14m) from write freeze through verified prod traffic.
- Final AWS session cost: pending Cost Explorer finalization (data lags ~24 hours).

## Timeline

| Event | Timestamp (UTC) | Evidence |
|---|---|---|
| Disaster declared | 2026-07-22 12:54:40 | `drill-events.log` |
| User-visible outage confirmed | 2026-07-22 12:54:58 | `08-primary-outage.png`, target health |
| Failover invoked | 2026-07-22 12:55:20 | `drill-events.log` |
| Replica promoted | 2026-07-22 12:59:50 | `drill-events.log` |
| DR service stable | 2026-07-22 13:02:26 | `drill-events.log` |
| DR write verified | 2026-07-22 13:02:57 | `drill-events.log` |
| Traffic switched and DR verified | 2026-07-22 13:03:56 | ARC, authoritative DNS, `09-dr-traffic-active.png` |
| DR writes frozen for failback | 2026-07-22 14:20:21 | `11-failback-write-freeze.png` |
| Prod traffic verified | 2026-07-22 14:34:21 | ARC, DNS, `12-prod-traffic-restored.png` |
| Pilot-light infrastructure reset | 2026-07-22 15:15:15 | workflow run `29929581941` |
| Credential reconciliation | 2026-07-22 | workflow run `29933402876` |
| Final reset health verified | 2026-07-22 17:40 | 200 OK, 2/2 prod tasks, DR 0/0 replica, `13-final-prod-healthy.png` |
| Safety snapshot deleted | 2026-07-22 17:33 | `drill-events.log`, `DBSnapshotNotFound` |

## Layer Results

| Layer | Scenario | Result | Evidence |
|---|---|---|---|
| ECS replacement | Stop one task | Passed, 61s replacement | `01-baseline-prod.png`, drill log |
| ECS AZ capacity | Stop tasks observed in one AZ | Passed, 69s recovery; not a complete AZ outage | `02-pre-az-retry.png` through `04-az-recovered.png` |
| RDS Multi-AZ | Forced failover | Passed, 432s recovery; one failed five-second health sample | `05-rds-failover-during.png`, `06-rds-failover-recovered.png` |
| Deployment safety | Broken image rollback | Passed in M3, approximately 3m01s on repeat | drill evidence |
| Regional DR | Promote DR and switch ARC | Passed, RTO 538s, row RPO 0s | `07-pre-regional-drill.png` through `10-dr-multiaz.png` |

## Improvements

- Failback topology operations originally assumed one uninterrupted workflow run. Live replacement failure proved that unsafe. PRs #22 and #23 made preparation and reset resumable from observed AWS topology.
- Replica promotion preserves the inherited database password, but Terraform's write-only password version has no readable value after a resource changes from replica to standalone. Reset generated a mismatched credential and caused public 503 responses after infrastructure restoration.
- PR #24 assigns promoted-replica credential ownership to the inherited password through `ignore_changes` and adds a typed break-glass reconciliation using the existing SSM SecureString. This avoids routine Terraform credential-version edits and keeps plaintext out of state and logs.
- Snapshot `sentinel-aws-dr-dr-pre-failback-20260722131547` was created as a safety measure before failback, validated against the active DR writer, and deleted after reset completion. All checks passed: source, freshness, encryption, availability, and Multi-AZ.

## Failback Status

**Complete.** Failback data preservation, reverse replication, write freeze, prod promotion, latest-row verification, Multi-AZ hardening, ARC return, snapshot lifecycle (create-validate-delete), credential reconciliation, and primary-to-DR replica rebuild all executed. Planned interruption from write freeze through verified prod traffic was 840s (14m). Final topology: prod 2/2 tasks, Multi-AZ writer in eu-central-1b, DR 0/0 tasks as read replica. All evidence retained in `docs/evidence/m6/`.
