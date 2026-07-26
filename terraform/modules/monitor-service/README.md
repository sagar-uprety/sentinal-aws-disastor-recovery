# Monitor Service Module

Runs the isolated Sentinel monitoring application on ECS Fargate with monitor-owned persistence and read-only workload topology access.

## Design Intent

The service remains outside workload Terraform state, routing controls, databases, and drill automation so workload failure injection cannot take its observer down.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11, < 2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.56.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_log_group.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_ecs_cluster.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_cluster) | resource |
| [aws_ecs_service.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service) | resource |
| [aws_ecs_task_definition.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_task_definition) | resource |
| [aws_iam_role.task](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.task_execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.runtime](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.task_execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_security_group.ecs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_alb_security_group_id"></a> [alb\_security\_group\_id](#input\_alb\_security\_group\_id) | ID of the ALB security group allowed to reach monitor tasks. | `string` | n/a | yes |
| <a name="input_app_subnet_ids"></a> [app\_subnet\_ids](#input\_app\_subnet\_ids) | IDs of private subnets for monitor tasks. | `list(string)` | n/a | yes |
| <a name="input_container_port"></a> [container\_port](#input\_container\_port) | Container port for monitor HTTP traffic. | `number` | `8080` | no |
| <a name="input_deploy_service"></a> [deploy\_service](#input\_deploy\_service) | Create the monitor task definition and ECS service. | `bool` | `true` | no |
| <a name="input_desired_count"></a> [desired\_count](#input\_desired\_count) | Number of isolated monitor tasks to run. | `number` | `1` | no |
| <a name="input_dr_database_identifier"></a> [dr\_database\_identifier](#input\_dr\_database\_identifier) | DR RDS instance identifier observed by the monitor. | `string` | n/a | yes |
| <a name="input_dr_ecs_cluster"></a> [dr\_ecs\_cluster](#input\_dr\_ecs\_cluster) | DR ECS cluster name observed by the monitor. | `string` | n/a | yes |
| <a name="input_dr_ecs_service"></a> [dr\_ecs\_service](#input\_dr\_ecs\_service) | DR ECS service name observed by the monitor. | `string` | n/a | yes |
| <a name="input_dr_region"></a> [dr\_region](#input\_dr\_region) | AWS Region containing the DR workload. | `string` | n/a | yes |
| <a name="input_dynamodb_table_arn"></a> [dynamodb\_table\_arn](#input\_dynamodb\_table\_arn) | ARN of the monitor-owned DynamoDB table. | `string` | n/a | yes |
| <a name="input_dynamodb_table_name"></a> [dynamodb\_table\_name](#input\_dynamodb\_table\_name) | Name of the monitor-owned DynamoDB table. | `string` | n/a | yes |
| <a name="input_environment"></a> [environment](#input\_environment) | Deployment environment name. | `string` | n/a | yes |
| <a name="input_image_uri"></a> [image\_uri](#input\_image\_uri) | Monitor ECR image URI with immutable digest. | `string` | n/a | yes |
| <a name="input_monitored_url"></a> [monitored\_url](#input\_monitored\_url) | Canonical workload health URL checked by the monitor. | `string` | n/a | yes |
| <a name="input_prod_database_identifier"></a> [prod\_database\_identifier](#input\_prod\_database\_identifier) | Prod RDS instance identifier observed by the monitor. | `string` | n/a | yes |
| <a name="input_prod_ecs_cluster"></a> [prod\_ecs\_cluster](#input\_prod\_ecs\_cluster) | Prod ECS cluster name observed by the monitor. | `string` | n/a | yes |
| <a name="input_prod_ecs_service"></a> [prod\_ecs\_service](#input\_prod\_ecs\_service) | Prod ECS service name observed by the monitor. | `string` | n/a | yes |
| <a name="input_prod_region"></a> [prod\_region](#input\_prod\_region) | AWS Region containing the primary workload. | `string` | n/a | yes |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name used for resource naming. | `string` | n/a | yes |
| <a name="input_target_group_arn"></a> [target\_group\_arn](#input\_target\_group\_arn) | ARN of the monitor ALB target group. | `string` | n/a | yes |
| <a name="input_task_cpu"></a> [task\_cpu](#input\_task\_cpu) | CPU units per monitor task. | `number` | `256` | no |
| <a name="input_task_memory"></a> [task\_memory](#input\_task\_memory) | Memory in MiB per monitor task. | `number` | `512` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | ID of the isolated monitoring VPC. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_cluster_arn"></a> [cluster\_arn](#output\_cluster\_arn) | ARN of the isolated monitoring ECS cluster. |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | Name of the isolated monitoring ECS cluster. |
| <a name="output_security_group_id"></a> [security\_group\_id](#output\_security\_group\_id) | ID of the monitor task security group. |
| <a name="output_service_arn"></a> [service\_arn](#output\_service\_arn) | ARN of the monitor ECS service, or null before service deployment. |
| <a name="output_task_execution_role_arn"></a> [task\_execution\_role\_arn](#output\_task\_execution\_role\_arn) | ARN of the monitor ECS task execution role. |
| <a name="output_task_role_arn"></a> [task\_role\_arn](#output\_task\_role\_arn) | ARN of the monitor ECS runtime role. |
<!-- END_TF_DOCS -->
