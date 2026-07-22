# Milestone 6 AWS Architecture Audit

Audit date: 2026-07-22. This is design-review evidence, not M6 completion evidence.

Manual deployment run `29911585417` completed prod foundation, immutable image publication, prod service deployment, and ECR replication. It failed during `Plan DR pilot light` because `terraform/environments/dr/acm.tf` contained import blocks for two certificates deleted during the baseline teardown. No DR resources were applied by that run.

## Confirmed Architecture

- The DR design is pilot light: cross-Region RDS data and core regional infrastructure remain provisioned while DR ECS stays at desired count zero until recovery. This matches AWS pilot-light guidance.
- Prod RDS Multi-AZ and ECS tasks across two Availability Zones are valid in-Region HA mechanisms. The controlled ECS AZ drill demonstrates application-capacity loss, not a complete AWS Availability Zone outage.
- Promoting the RDS PostgreSQL cross-Region read replica, validating DR compute and writes, and only then switching traffic is the correct recovery order.
- ARC `RECOVERY_CONTROL` health checks, an atomic two-control update, and safety rules enforcing exactly one active Region correctly prevent automatic routing to an unready pilot light.
- Cross-Region automated backup replication and the historical isolated PITR drill correctly cover corruption scenarios that asynchronous replication alone does not protect against.

## Implemented, Pending Live Validation

- `failback.sh snapshot` snapshots the active DR writer before destructive reverse replication.
- Failback freezes DR compute and writes, retains the final observed DR row, rechecks fresh reverse-replica lag evidence immediately before promotion, and verifies that row on promoted prod before traffic moves. DR and prod are never active writers together.
- Recovery workflows retain typed confirmations and apply exact saved Terraform plans in dependent jobs. Independent post-plan approval is documented as a production hardening step, not a showcase requirement.
- `recovery.yml` validates active-DR snapshot source, creation time, encryption, naming, availability, and Multi-AZ state.
- `switch-traffic.sh` initializes ARC state, atomically updates both controls through retried data-plane endpoints, and documents its acceptable demo-time control-plane discovery dependency.
- Detection-only Route53 checks reach the real HTTP `/healthz` forwarding rule instead of the redirect response.
- DR standby alarms tolerate intentional zero capacity; failover activates both ECS and ALB thresholds, and Terraform reset restores standby semantics.
- Disaster simulation retains the newest row observed while ECS drains before confirming zero healthy targets. Forced RDS Multi-AZ testing verifies a known row before and after failover.

Repository validation passes, including Terraform validation and TFLint, Checkov, actionlint, Go tests with race detection, `go vet`, `govulncheck`, shell syntax, and a local DR plan. M6 remains incomplete until live evidence verifies behavior against AWS.

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
