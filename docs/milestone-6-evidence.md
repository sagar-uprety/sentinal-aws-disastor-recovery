# Milestone 6 Evidence

Verified on 2026-07-22 in `eu-central-1` and `eu-west-1`. This file records completed live work and preserves incomplete gates as incomplete. Raw timestamps are retained in `docs/evidence/m6/drill-events.log`; screenshots are retained beside it.

## Deployment And Security Baseline

- Run `29911585417` began from no workload resources, created healthy primary infrastructure, published the immutable image, and verified ECR replication. It stopped before secondary apply because deleted ACM certificates were still referenced by stale import blocks.
- PR #21 removed stale imports and hardened drill checks. Main run `29917714546` safely resumed the reviewed configuration, applied the secondary pilot light in 24m46s, and verified secondary ECS desired count zero.
- Primary ran two ECS tasks across `eu-central-1a` and `eu-central-1b`; primary RDS was PostgreSQL 18.4, `db.t4g.micro`, encrypted, and Multi-AZ. Secondary held the matching encrypted cross-Region replica at zero ECS tasks.
- Applied primary and secondary state snapshots were searched for populated database-password fields and the generated credential value. No plaintext credential was found. Evidence retained only write-only field names, synchronized version metadata, and redacted SSM/RDS properties.

## In-Region HA

| Test | Measured result | Evidence |
|---|---:|---|
| Stop one ECS task | Replacement verified in 61s | `01-baseline-primary.png`, drill log |
| Stop tasks observed in one AZ | Two-AZ capacity restored in 69s | `02-pre-az-retry.png` through `04-az-recovered.png`, drill log |
| Force RDS Multi-AZ failover | Recovered in 432s; one failed five-second health sample | `05-rds-failover-during.png`, `06-rds-failover-recovered.png`, drill log |

The ECS AZ test removed observed application tasks from `eu-central-1a`; it did not simulate loss of every AWS service in that Availability Zone. RDS moved its writer from `eu-central-1a` to `eu-central-1b`, moved the managed standby in the opposite direction, and retained the known row recorded before failover.

## Regional Drill

| Event | UTC |
|---|---|
| Disaster declared | 2026-07-22 12:54:40 |
| User-visible outage confirmed | 2026-07-22 12:54:58 |
| Failover invoked | 2026-07-22 12:55:20 |
| Replica promoted | 2026-07-22 12:59:50 |
| Secondary targets healthy | 2026-07-22 13:02:30 |
| Secondary write verified | 2026-07-22 13:02:57 |
| Public secondary traffic verified | 2026-07-22 13:03:56 |

- End-to-end RTO: 538s (8m58s), target 30 minutes, met.
- Failover invocation to fresh secondary write: 457s (7m37s).
- Failover invocation to verified public secondary traffic: 516s (8m36s).
- Row-based observed RPO: 0s, target 60s, met.
- Fresh pre-promotion CloudWatch `ReplicaLag`: 12s.
- Secondary ECS reached two healthy targets across two AZs before routing changed.
- ARC changed primary `Off` and secondary `On` atomically. Authoritative DNS and `/topology` proved `eu-west-1` served the canonical hostname.
- Promoted secondary RDS was converted to Multi-AZ after service recovery; this hardening was outside RTO.

The row-based RPO compares the newest canonical-target check observed during primary drain with the matching row present in secondary. It proves that observed application row survived; it does not prove every source transaction committed at the boundary.

Screenshots: `07-pre-regional-drill.png`, `08-primary-outage.png`, `09-secondary-traffic-active.png`, and `10-secondary-multiaz.png`.

## Failback And Reset

- Active-writer snapshot: `sentinel-aws-secondary-secondary-pre-failback-20260722131547`.
- Failed prepare run `29923312392` exposed non-resumable replacement behavior without losing active secondary data.
- PR #22 made promotion and reverse-replica operations resumable.
- Prepare run `29924895255` validated the snapshot, applied the exact saved reverse-replica plan, and verified primary replicated from secondary.
- Reverse-replica lag before freeze: 0s.
- Secondary writes frozen: 2026-07-22 14:20:21 UTC.
- Primary promoted: 2026-07-22 14:20:45 UTC.
- Primary stable: 2026-07-22 14:33:36 UTC.
- Public primary traffic verified: 2026-07-22 14:34:21 UTC.
- Planned failback interruption: 840s (14m) from write freeze through public primary verification.
- Final observed secondary row was verified on promoted primary before routing changed.
- PR #23 completed reset resumption. Run `29929581941` reconciled primary to standalone and rebuilt secondary as primary's replica with secondary ECS desired count zero.
- Reset exposed a credential ownership gap: Terraform reconciliation generated a new write-only value while the promoted database retained its inherited password. PR #24 preserves inherited credentials during normal replica promotion/reset and adds a typed break-glass repair that reuses the existing SSM SecureString without changing a Terraform version counter.

Screenshots: `11-failback-write-freeze.png` and `12-primary-traffic-restored.png`.

## Workflow Evidence

| Purpose | Run | Result |
|---|---:|---|
| Initial from-zero M6 deployment | `29911585417` | Partial, stopped at stale secondary import |
| Completed pilot-light deployment | `29917714546` | Success |
| First failback prepare | `29923312392` | Failed safely |
| Resumable failback prepare | `29924895255` | Success |
| Pilot-light topology reset | `29929581941` | Success |
| Credential-preservation PR plan | `29933179893` | Success |
| Credential reconciliation | `29933402876` | Pending at this evidence update |

PRs #22, #23, and #24 retain code review and speculative-plan history for fixes discovered during the live drill.

## Remaining M6 Gates

- Complete credential reconciliation and retain final healthy primary screenshot or `/topology` export.
- Delete the temporary active-secondary safety snapshot after final reset evidence.
- Generate and test the CloudTrail-derived least-privilege deployment policy, then remove `PowerUserAccess`.
- Record actual Cost Explorer amount and total session duration.
- Complete final README, architecture export, and teardown, secondary before primary unless live topology requires otherwise.
