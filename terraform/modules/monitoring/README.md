# Monitoring Module

OTel Collector, Prometheus, and Grafana as three Fargate ECS services in the private application subnets, wired together over an AWS Cloud Map private DNS namespace.

## Design Intent

The Sentinel app pushes OTLP metrics to the collector; the collector re-exposes them in Prometheus format; Prometheus scrapes the collector; Grafana queries Prometheus through a provisioned datasource and a provisioned "Sentinel" dashboard. Security groups are chained the same way traffic flows (app -> collector <- Prometheus <- Grafana), so nothing but the app can reach the collector and nothing but Grafana can query Prometheus. There is no public entry point: Grafana is reached only through `aws ecs execute-command` / SSM port-forwarding (`enable_execute_command = true`), matching the plan's "SSM port-forward for the demo" option, so no ALB listener, auth system, or public metrics endpoint is needed. Grafana runs with anonymous viewer access since it is unreachable from the internet.

Prometheus and Grafana configs are generated at container start from environment-injected heredocs (`entryPoint = ["/bin/sh", "-c"]`) rather than a mounted volume or EFS, since the config is small and static per apply; this avoids a filesystem dependency for a demo-scale, single-task service.

Alerting lives in the same module (`alerting.tf`): one SNS topic with an email subscription receives five CloudWatch alarms (ALB 5xx, ALB healthy host count, ECS running task count, RDS CPU, RDS free storage) plus an EventBridge rule on the ECS deployment circuit breaker's `SERVICE_DEPLOYMENT_FAILED` event. This matches the plan's single "Monitoring" section (4.6) covering both the observability stack and alerting, and the repo layout's single `monitoring` module.

## Inputs

| Name | Description | Type | Default |
|---|---|---|---|
| `project_name` | Project name | `string` | — |
| `environment` | Deployment environment | `string` | — |
| `vpc_id` | VPC ID | `string` | — |
| `app_subnet_ids` | Application private subnet IDs | `list(string)` | — |
| `ecs_cluster_name` | Existing ECS cluster to run these services in | `string` | — |
| `app_security_group_id` | Sentinel app ECS security group, allowed to push OTLP | `string` | — |
| `alb_arn_suffix` | ALB ARN suffix, for CloudWatch alarm dimensions | `string` | — |
| `target_group_arn_suffix` | Target group ARN suffix, for CloudWatch alarm dimensions | `string` | — |
| `ecs_desired_count` | App service desired task count (alarm threshold) | `number` | `2` |
| `alert_email` | Email subscribed to the alerts SNS topic | `string` | — |

## Outputs

| Name | Description |
|---|---|
| `otel_collector_endpoint` | OTLP HTTP endpoint for the app's `otel_endpoint` variable |
| `grafana_service_name` | ECS service name for SSM port-forward access |
| `namespace` | Cloud Map private DNS namespace name |
| `sns_topic_arn` | SNS topic ARN for alarms and the deployment-failure EventBridge rule |

## Cost Notes

Three additional Fargate ARM64 tasks at 256 CPU / 512 MB each (desired_count = 1, no HA needed for an internal observability stack), roughly $10/task/month if left running continuously. Prometheus retention is capped at 24h (`--storage.tsdb.retention.time=24h`) to bound ephemeral storage growth. No interface endpoints, no EFS, no ALB target group added. CloudWatch alarms, SNS, and EventBridge are effectively free at this volume (a handful of alarms and near-zero notification traffic). CloudWatch log group retention is 365 days per Checkov (CKV_AWS_338); irrelevant in practice since the whole environment is destroyed between sessions.

## IAM Exceptions

`ssmmessages:CreateControlChannel` / `CreateDataChannel` / `OpenControlChannel` / `OpenDataChannel` on the Grafana task role use `Resource = "*"`; these ECS Exec channel actions do not support resource-level scoping. Documented exception per Hard Rule 7.
