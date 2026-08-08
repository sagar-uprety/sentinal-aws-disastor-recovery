# RDS Module

PostgreSQL 18 database with write-only credentials and encrypted storage.

## Design Intent

Single RDS instance in isolated database subnets. The master password flows through `password_wo` (write-only) so plaintext never enters Terraform state. The environment layer resolves the engine version and passes it in. A security group restricts access to the ECS tasks only. Demo settings: `deletion_protection = false`, `skip_final_snapshot = true`.

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
| [aws_db_instance.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance) | resource |
| [aws_db_parameter_group.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_parameter_group) | resource |
| [aws_db_subnet_group.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_subnet_group) | resource |
| [aws_iam_role.rds_monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.rds_monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_security_group.rds](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_db_name"></a> [db\_name](#input\_db\_name) | Name of the application database. | `string` | `"pilotlight"` | no |
| <a name="input_db_subnet_ids"></a> [db\_subnet\_ids](#input\_db\_subnet\_ids) | IDs of the isolated database subnets. | `list(string)` | n/a | yes |
| <a name="input_ecs_security_group_id"></a> [ecs\_security\_group\_id](#input\_ecs\_security\_group\_id) | ID of the ECS security group granted access to the database. | `string` | n/a | yes |
| <a name="input_engine_version"></a> [engine\_version](#input\_engine\_version) | PostgreSQL engine version resolved via aws\_rds\_engine\_version. | `string` | n/a | yes |
| <a name="input_environment"></a> [environment](#input\_environment) | Deployment environment name. | `string` | n/a | yes |
| <a name="input_instance_class"></a> [instance\_class](#input\_instance\_class) | RDS instance class (e.g., db.t4g.micro). | `string` | n/a | yes |
| <a name="input_kms_key_id"></a> [kms\_key\_id](#input\_kms\_key\_id) | Destination-region KMS key ARN for encrypting replica storage. Required when replicate\_source\_db\_arn is set. | `string` | `null` | no |
| <a name="input_multi_az"></a> [multi\_az](#input\_multi\_az) | Enable Multi-AZ for high availability testing. | `bool` | `false` | no |
| <a name="input_password_wo"></a> [password\_wo](#input\_password\_wo) | Master database password (write-only). Ignored when replicate\_source\_db\_arn is set; replicas inherit the source instance's credentials. | `string` | `""` | no |
| <a name="input_password_wo_version"></a> [password\_wo\_version](#input\_password\_wo\_version) | Version counter for password\_wo rotation. Ignored when replicate\_source\_db\_arn is set. | `number` | `1` | no |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name for resource naming. | `string` | n/a | yes |
| <a name="input_replicate_source_db_arn"></a> [replicate\_source\_db\_arn](#input\_replicate\_source\_db\_arn) | ARN of the source RDS instance to replicate. Set to create a cross-region read replica instead of a standalone instance. | `string` | `null` | no |
| <a name="input_username"></a> [username](#input\_username) | Master database username. | `string` | `"pilotlight"` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | ID of the VPC. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_address"></a> [address](#output\_address) | RDS hostname. |
| <a name="output_arn"></a> [arn](#output\_arn) | ARN of the RDS instance, for cross-region replication and IAM policies. |
| <a name="output_endpoint"></a> [endpoint](#output\_endpoint) | RDS connection endpoint. |
| <a name="output_port"></a> [port](#output\_port) | RDS port. |
| <a name="output_security_group_id"></a> [security\_group\_id](#output\_security\_group\_id) | ID of the RDS security group. |
<!-- END_TF_DOCS -->
