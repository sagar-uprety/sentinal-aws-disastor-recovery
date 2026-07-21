# Monitoring Module

CloudWatch alarms, SNS notifications, and an EventBridge notification for failed ECS deployments.

## Design Intent

AWS-native monitoring detects workload and dependency failures in each region without adding an observability ECS stack to the workload failure domain. The module sends ALB, ECS, and RDS alarm state changes plus ECS deployment failures to one SNS email subscription.

## Inputs

| Name | Description |
|---|---|
| `alb_arn_suffix` | ALB ARN suffix used in CloudWatch alarm dimensions. |
| `alert_email` | Email address subscribed to alerts. |
| `ecs_cluster_name` | ECS cluster name used in the running-task alarm. |
| `ecs_desired_count` | Expected app task count used in the running-task alarm. |
| `environment` | Deployment environment name. |
| `project_name` | Project name for resource naming. |
| `target_group_arn_suffix` | Target group ARN suffix used in CloudWatch alarm dimensions. |

## Outputs

| Name | Description |
|---|---|
| `sns_topic_arn` | SNS topic receiving CloudWatch and EventBridge notifications. |

## Cost Notes

CloudWatch alarms, EventBridge, and SNS have negligible cost at this project's volume. Application logs remain in the ECS service CloudWatch Logs groups; no logs or metrics are archived to S3.
