# ECS Service Module

Fargate cluster with a single service, ARM64 runtime, circuit breaker, and SSM-secured database credentials.

## Design Intent

Tasks run in private application subnets behind the ALB security group. The task execution role receives narrowly scoped `ssm:GetParameters` on one regional SecureString ARN and `kms:Decrypt` for the region-local KMS key. The service ships with a deployment circuit breaker (`enable = true`, `rollback = true`) using the provider-supported defaults. `deploy_service = false` allows the first M2 phase to create supporting resources before an image is available.

**Fargate platform:** `operating_system_family = "LINUX"`, `cpu_architecture = "ARM64"` (Graviton). Pinned explicitly rather than relying on `LATEST`.

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
| [aws_cloudwatch_log_group.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_ecs_cluster.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_cluster) | resource |
| [aws_ecs_service.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service) | resource |
| [aws_ecs_task_definition.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_task_definition) | resource |
| [aws_iam_role.task](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.task_execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.ecs_topology](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.rds_topology](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.ssm_access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.task_execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_security_group.ecs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_alb_security_group_id"></a> [alb\_security\_group\_id](#input\_alb\_security\_group\_id) | ID of the ALB security group allowed to send HTTP traffic. | `string` | n/a | yes |
| <a name="input_app_subnet_ids"></a> [app\_subnet\_ids](#input\_app\_subnet\_ids) | IDs of the application private subnets. | `list(string)` | n/a | yes |
| <a name="input_container_port"></a> [container\_port](#input\_container\_port) | Container port for HTTP traffic. | `number` | `8080` | no |
| <a name="input_db_endpoint"></a> [db\_endpoint](#input\_db\_endpoint) | RDS connection endpoint (host:port). | `string` | n/a | yes |
| <a name="input_db_instance_identifier"></a> [db\_instance\_identifier](#input\_db\_instance\_identifier) | RDS DB instance identifier queried by the status page for topology metadata. | `string` | n/a | yes |
| <a name="input_db_name"></a> [db\_name](#input\_db\_name) | Application database name. | `string` | n/a | yes |
| <a name="input_db_password_ssm_arn"></a> [db\_password\_ssm\_arn](#input\_db\_password\_ssm\_arn) | ARN of the SSM SecureString parameter holding the database password. | `string` | n/a | yes |
| <a name="input_db_user"></a> [db\_user](#input\_db\_user) | Database master username. | `string` | n/a | yes |
| <a name="input_deploy_service"></a> [deploy\_service](#input\_deploy\_service) | Create the ECS service. Set false for the foundation phase. | `bool` | `true` | no |
| <a name="input_desired_count"></a> [desired\_count](#input\_desired\_count) | Number of ECS tasks to run. | `number` | `2` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Deployment environment name. | `string` | n/a | yes |
| <a name="input_image_uri"></a> [image\_uri](#input\_image\_uri) | ECR image URI with immutable digest. | `string` | n/a | yes |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name for resource naming. | `string` | n/a | yes |
| <a name="input_target_group_arn"></a> [target\_group\_arn](#input\_target\_group\_arn) | ARN of the ALB target group. | `string` | n/a | yes |
| <a name="input_task_cpu"></a> [task\_cpu](#input\_task\_cpu) | vCPU units per task. | `number` | `256` | no |
| <a name="input_task_memory"></a> [task\_memory](#input\_task\_memory) | Memory MiB per task. | `number` | `512` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | ID of the VPC. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_cluster_arn"></a> [cluster\_arn](#output\_cluster\_arn) | ARN of the ECS cluster. |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | Name of the ECS cluster. |
| <a name="output_security_group_id"></a> [security\_group\_id](#output\_security\_group\_id) | ID of the ECS tasks security group. |
| <a name="output_task_execution_role_arn"></a> [task\_execution\_role\_arn](#output\_task\_execution\_role\_arn) | ARN of the ECS task execution IAM role. |
| <a name="output_task_role_arn"></a> [task\_role\_arn](#output\_task\_role\_arn) | ARN of the application task role used for runtime topology reads. |
<!-- END_TF_DOCS -->

## IAM Exceptions

`kms:Decrypt` uses `Resource = "*"` scoped to the region-local KMS key ARN prefix. The SSM key ARN cannot be known before the parameter exists. This exception is documented per Hard Rule 7.
