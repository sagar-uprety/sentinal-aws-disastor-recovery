# Route53 Failover Module

Operator-gated traffic switching between prod and DR via Route53 Application Recovery Controller (ARC).

## Design Intent

Two Route53 failover records at the same name, each health-gated by a `RECOVERY_CONTROL` health check tied to an ARC routing control's manual On/Off state rather than real ALB health -- so the DNS switch only ever happens when an operator (or a script acting on their behalf) flips the ARC control via its data-plane API, never automatically. Two safety rules block the cluster from ever having both controls On or both Off simultaneously.

## Cost

The ARC cluster is billed per cluster-hour while it exists (published rate $2.50/cluster-hour at last check; verify current pricing before apply). Provision only for the drill and destroy after recording, per the project owner's teardown decision. The two `aws_route53_health_check` resources and Route53 records are billed at Route53's normal per-health-check / per-hosted-zone rates, not part of the ARC hourly charge.

## Inputs

| Name | Description | Type | Default |
|---|---|---|---|
| `project_name` | Project name for resource naming | `string` | — |
| `route53_zone_id` | Hosted zone ID of the delegated sentinel.sagaruprety.com.np zone | `string` | — |
| `record_name` | Fully qualified record name the failover pair is published under | `string` | — |
| `primary_alb_dns_name` | DNS name of the primary (prod) ALB | `string` | — |
| `primary_alb_zone_id` | Canonical hosted zone ID of the primary (prod) ALB | `string` | — |
| `dr_alb_dns_name` | DNS name of the DR ALB | `string` | — |
| `dr_alb_zone_id` | Canonical hosted zone ID of the DR ALB | `string` | — |

## Outputs

| Name | Description |
|---|---|
| `cluster_arn` | ARN of the ARC routing control cluster |
| `primary_routing_control_arn` | ARN of the primary routing control |
| `dr_routing_control_arn` | ARN of the DR routing control |
