# Milestone 6 AWS Architecture Audit

Audit date: 2026-07-22. Design conclusions below were subsequently exercised in the live M6 drill; measured results are in `docs/milestone-6-evidence.md`.

Manual deployment run `29911585417` completed primary foundation, immutable image publication, primary service deployment, and ECR replication. It failed during `Plan secondary pilot light` because `terraform/environments/secondary/acm.tf` contained import blocks for two certificates deleted during the baseline teardown. No secondary resources were applied by that run.

## Confirmed Architecture

- The secondary design is pilot light: cross-Region RDS data and core regional infrastructure remain provisioned while secondary ECS stays at desired count zero until recovery. This matches AWS pilot-light guidance.
- Primary RDS Multi-AZ and ECS tasks across two Availability Zones are valid in-Region HA mechanisms. The controlled ECS AZ drill demonstrates application-capacity loss, not a complete AWS Availability Zone outage.
- Promoting the RDS PostgreSQL cross-Region read replica, validating secondary compute and writes, and only then switching traffic is the correct recovery order.
- ARC `RECOVERY_CONTROL` health checks, an atomic two-control update, and safety rules enforcing exactly one active Region correctly prevent automatic routing to an unready pilot light.
- Cross-Region automated backup replication and the historical isolated PITR drill correctly cover corruption scenarios that asynchronous replication alone does not protect against.

## Live Validation Result

- `failback.sh snapshot` created and validated the active-secondary safety snapshot before reverse replication.
- Failback froze secondary compute and writes, retained the final observed secondary row, rechecked 0s reverse-replica lag, and verified that row on promoted primary before traffic moved. Secondary and primary were never independent active writers.
- Recovery runs `29924895255` and `29929581941` applied exact saved plans behind typed confirmations and restored primary-to-secondary pilot-light topology.
- `switch-traffic.sh` initialized ARC state and atomically moved both controls through regional data-plane endpoints in both directions.
- Detection-only Route53 checks reached the HTTP `/healthz` forwarding rule and remained separate from routing controls.
- Secondary standby alarms tolerated intentional zero capacity, activated ECS and ALB thresholds during failover, and returned to standby semantics during reset.
- Disaster simulation retained the newest primary row during drain. Regional failover achieved 538s RTO and 0s row-based observed RPO with 12s fresh `ReplicaLag` evidence.
- Forced RDS Multi-AZ testing retained its known row and moved writer and standby AZs, recovering in 432s.

Repository validation passes, including Terraform validation and TFLint, Checkov, actionlint, Go tests with race detection, `go vet`, `govulncheck`, shell syntax, and reviewed workflow plans. M6 remains incomplete only for the explicit gates listed in `docs/milestone-6-evidence.md`, including final credential health, least-privilege IAM, cost, final documentation, snapshot deletion, and teardown.

## Scope Decision

One final regional drill plus a fully verified failback/topology reset is mandatory. A second regional drill is optional after M6. This reduces cost and time while retaining proof of failover, traffic switching, reverse replication, single-writer restoration, and pilot-light reset.

## AWS References

- [Disaster recovery options: pilot light](https://docs.aws.amazon.com/whitepapers/latest/disaster-recovery-workloads-on-aws/disaster-recovery-options-in-the-cloud.html)
- [Testing disaster recovery](https://docs.aws.amazon.com/whitepapers/latest/disaster-recovery-workloads-on-aws/testing-disaster-recovery.html)
- [Promoting an RDS read replica](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ReadRepl.Promote.html)
- [RDS PostgreSQL read replicas](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PostgreSQL.Replication.ReadReplicas.html)
- [Route53 ARC routing controls](https://docs.aws.amazon.com/r53recovery/latest/dg/routing-control.html)
- [Avoid ARC control-plane dependencies](https://docs.aws.amazon.com/whitepapers/latest/aws-fault-isolation-boundaries/appendix-a---partitional-service-guidance.html)
- [ECS Availability Zone balancing](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service-rebalancing.html)
- [Route53 health-check redirect behavior](https://aws.amazon.com/route53/faqs/)
