# Alerting Module

CloudWatch alarms (ALB, ECS, RDS) plus an EventBridge rule for failed ECS deployments, routed to one SNS email subscription. Deliberately AWS-native rather than a separate observability ECS stack, so the monitoring path doesn't share a failure domain with the workload it watches.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11, < 2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.55.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_event_rule.ecs_deployment_failed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.ecs_deployment_failed_sns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_metric_alarm.alb_5xx](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.alb_healthy_hosts](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.ecs_running_tasks](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.rds_cpu](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.rds_free_storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_sns_topic.alerts](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_policy.publishers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_policy) | resource |
| [aws_sns_topic_subscription.email](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_alb_arn_suffix"></a> [alb\_arn\_suffix](#input\_alb\_arn\_suffix) | ARN suffix of the ALB, for CloudWatch alarm dimensions. | `string` | n/a | yes |
| <a name="input_alert_email"></a> [alert\_email](#input\_alert\_email) | Email address subscribed to the alerts SNS topic. | `string` | n/a | yes |
| <a name="input_create_rds_alarms"></a> [create\_rds\_alarms](#input\_create\_rds\_alarms) | Create the RDS CPU/free-storage alarms. False for environments with no RDS instance. | `bool` | `true` | no |
| <a name="input_deployment_failed_service_arns"></a> [deployment\_failed\_service\_arns](#input\_deployment\_failed\_service\_arns) | ECS service ARNs matched by the deployment-failure rule. Null (default) self-scopes to this service. | `list(string)` | `null` | no |
| <a name="input_ecs_cluster_name"></a> [ecs\_cluster\_name](#input\_ecs\_cluster\_name) | ECS cluster name used in the running-task-count alarm. | `string` | n/a | yes |
| <a name="input_ecs_desired_count"></a> [ecs\_desired\_count](#input\_ecs\_desired\_count) | Desired ECS task count for the app service, used as the running-task-count alarm threshold. | `number` | `2` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Deployment environment name. | `string` | n/a | yes |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name for resource naming. | `string` | n/a | yes |
| <a name="input_target_group_arn_suffix"></a> [target\_group\_arn\_suffix](#input\_target\_group\_arn\_suffix) | ARN suffix of the ALB target group, for CloudWatch alarm dimensions. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_sns_topic_arn"></a> [sns\_topic\_arn](#output\_sns\_topic\_arn) | SNS topic ARN that CloudWatch alarms and the ECS deployment-failure EventBridge rule notify. |
<!-- END_TF_DOCS -->
