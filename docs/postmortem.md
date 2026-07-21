# Disaster Recovery Drill Postmortem

Complete this document only after Milestone 6. Preserve measured timestamps and command output; do not replace pending fields with estimates.

## Scope

- Drill date:
- Git commit:
- AWS session start and end:
- Primary region: eu-central-1
- DR region: eu-west-1

## Executive Summary

- Scenario:
- User impact:
- End-to-end RTO target and measured result:
- Promotion-time RPO target and measured result:
- Topology-reset duration:
- Final AWS session cost:

## Timeline

| Event | Timestamp (UTC) | Evidence |
|---|---|---|
| Disaster declared | Pending | `drill-events.log` |
| User-visible outage confirmed | Pending | curl and target health |
| Failover invoked | Pending | `drill-events.log` |
| Replica promoted | Pending | `drill-events.log` |
| DR service stable | Pending | `drill-events.log` |
| DR write verified | Pending | `drill-events.log` |
| Traffic switched | Pending | ARC and DNS output |
| Topology reset complete | Pending | Terraform and RDS output |

## Layer Results

| Layer | Scenario | Result | Evidence |
|---|---|---|---|
| ECS replacement | Stop one task | Pending | Pending |
| RDS Multi-AZ | Forced failover | Pending | Existing M2 evidence or M6 revalidation |
| Deployment safety | Broken image rollback | Pending | Existing M3 evidence or M6 revalidation |
| Regional DR | Promote DR and switch ARC | Pending | Pending |

## Improvements

- Finding:
- Impact:
- Owner:
- Follow-up:

## Failback Status

State whether failback was fully executed and measured. If not, describe exactly which steps were executed and do not imply full validation.
