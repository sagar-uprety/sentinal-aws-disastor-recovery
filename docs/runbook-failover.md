# Failover Runbook

Measured against a real rehearsal executed 2026-07-17. Every number below is what was actually observed, not an estimate — where a step wasn't run twice, that's stated rather than implied.

## When to Use This

A confirmed regional failure or severe degradation of prod (eu-central-1) that ALB/ECS/RDS self-healing (Multi-AZ failover, circuit-breaker rollback) cannot address, because the failure is regional rather than a single AZ or a single bad deployment. Do not use this for problems those existing mechanisms already handle — check them first.

## Step-by-Step, With Measured Durations

| # | Step | Command | Measured duration | Notes |
|---|---|---|---|---|
| 1 | Declare the disaster | `scripts/simulate-disaster.sh` (drill) / operator judgment (real incident) | — | Sets prod ECS `desired_count=0` in a drill; in a real regional outage this step is the confirmed outage itself, not scripted |
| 2 | Confirm the outage is real | `curl -o /dev/null -w '%{http_code}' http://<prod-alb>/healthz` | ~30s (ALB `deregistration_delay`) | Got `200` briefly after scale-to-0 (draining), then `503` once targets fully drained — don't declare on the first check |
| 3 | Invoke failover | `scripts/failover.sh` | 532s (8m52s) end-to-end, `failover_invoked`→`dr_write_verified` | Promotes replica, registers a DR task definition against the promoted endpoint, scales DR to 2, waits for stability, verifies healthy targets and a fresh write |
| 3a | — replica promotion | `aws rds promote-read-replica` (inside the script) | included above; promotion + settle to `available` took the bulk of it | **Irreversible** — permanently ends replication from prod. See Failback below. |
| 3b | — DR scale-up | `aws ecs update-service --desired-count 2` (inside the script) | included above | Circuit breaker enabled; would auto-rollback the task definition if it kept failing |
| 4 | Verify DR is really ready | `aws elbv2 describe-target-health`, `curl .../status` | included above | Both targets `healthy`, `/status` showing check timestamps newer than the promotion |
| 5 | Switch traffic (operator-gated, separate step) | `aws route53-recovery-cluster update-routing-control-states --update-routing-control-state-entries RoutingControlArn=<primary>,RoutingControlState=Off RoutingControlArn=<dr>,RoutingControlState=On` | ~60-90s for Route53's `HealthCheckStatus` to propagate after the API call returns | **Single atomic call for both controls** — never two sequential calls, which would pass through an invalid intermediate state and trip a safety rule |
| 6 | Confirm traffic actually reached DR | `dig @<a-route53-nameserver> A status.sentinel.sagaruprety.com.np`, `curl http://status.sentinel.sagaruprety.com.np/healthz` | — | Query a Route53 nameserver directly, not a caching resolver |
| 7 | Post-recovery: harden DR to Multi-AZ | `aws rds modify-db-instance --multi-az --apply-immediately` | see `docs/milestone-4-evidence.md` for the measured window | Reported separately from RTO — this is hardening after recovery, not part of it |

**End-to-end RTO** (`disaster_declared` → `traffic_switched`): **736 seconds (12m16s)**, against the section 4.3 target of 30 minutes.
**Operator-invocation automation duration** (`failover_invoked` → `dr_write_verified`, i.e. how much of that 736s the scripts actually automated): **532 seconds (8m52s)**.
This was one rehearsal, not two — the M4 acceptance criterion requires one; running twice and reporting both is M5's job.

## RPO: Two Different Numbers for Two Different Failure Modes

**Replica-promotion path** (target: 60s): the honest measurement is replica lag *right before* promotion, not a post-hoc data comparison. `measure.sh` checks the newest row DR is serving against the disaster-declared timestamp — but that check is structurally blind once DR resumes writing new checks, which happens within seconds of the service scaling up. In this rehearsal, `ReplicaLag` measured continuously through the session sat at 10-17s, including immediately before the promotion call — that's the real data-loss window for this path, well under the 60s target.

**PITR corruption path** (no fixed target — section 4.3 says measure it, not assume it): **~12 minutes** observed, from a real drill (`docs/milestone-4-evidence.md`). This is a fundamentally different, much larger number than the replica-promotion RPO because it reflects the automated-backup replication mechanism's restore granularity, not continuous streaming replication. Use replica promotion for a live regional failure; reserve PITR restore for the scenario it actually targets — corrupted or deleted data, where promoting a replica would just promote the corruption.

## Post-Promotion Billing Cleanup

While DR is serving as primary: prod's original RDS instance is stopped receiving replication (but still running and billing), the ARC cluster continues billing at $2.50/cluster-hour, and DR is now running at full desired_count=2 rather than pilot-light 0. None of this is free-running infrastructure — the project owner controls teardown timing, but should not let a rehearsal or drill remain in "DR is primary" state indefinitely without being aware of the cost delta.

## Failback: Why the Old Primary Can't Just Resume

Once DR has accepted writes, prod's original database has diverged — it stopped replicating at the moment of promotion, while DR kept moving. "Failing back" is not restarting replication in reverse from where it left off.

**Safe path (reverse-replicate, verify, then switch back):**
1. `scripts/failback.sh snapshot` — snapshots the stale prod instance before touching it (a safety net, not a recovery mechanism).
2. Edit Terraform: point `environments/prod`'s `rds` module at DR (now primary) as the replication source — the same pattern DR's module already uses against prod, in reverse.
3. `terraform destroy -target=module.rds` in prod (removes the stale instance — the snapshot above is why this is safe), then `terraform apply` to create prod as a fresh replica of DR.
4. `scripts/failback.sh verify` — checks replica lag and prints a reminder to confirm a known DR-written row is present in the rebuilt prod replica.
5. Once caught up and verified: this is the point where a decision is made — either promote prod back and re-establish DR as its replica (full round-trip to the original topology), or continue running with DR as primary if that's now the intended steady state.

**Documented-but-not-required-here alternative (destructive, faster):** restore prod directly from the pre-failback snapshot instead of reverse-replicating. Faster, but discards every write made in DR after promotion. State the data-loss window and RTO explicitly if this path is ever used instead — it is not equivalent to the safe path and must never be presented as such.

## Scripted Route53 Fallback (Documented, Not Used in This Rehearsal)

If ARC itself is unavailable, a direct Route53 record update (`UPSERT` on the failover A-records) can move traffic without the data-plane API. This is explicitly a **less resilient control-plane operation** — it goes through Route53's regular API rather than ARC's purpose-built, highly-available data plane, and does not carry the same safety-rule guarantees against a bad state. Documented here as the emergency fallback; not exercised, and never to be presented as equivalent evidence to the ARC-gated switch actually measured above.
