# RDS Module

PostgreSQL 18 database with write-only credentials and encrypted storage.

## Design Intent

Single RDS instance in isolated database subnets. The master password flows through `password_wo` (write-only) so plaintext never enters Terraform state. The environment layer resolves the engine version and passes it in. A security group restricts access to the ECS tasks only. Demo settings: `deletion_protection = false`, `skip_final_snapshot = true`.

## Inputs

| Name | Description | Type | Default |
|---|---|---|---|
| `project_name` | Project name for resource naming | `string` | — |
| `environment` | Deployment environment name | `string` | — |
| `vpc_id` | ID of the VPC | `string` | — |
| `db_subnet_ids` | IDs of the isolated database subnets | `list(string)` | — |
| `ecs_security_group_id` | ID of the ECS security group | `string` | — |
| `engine_version` | Resolved PostgreSQL engine version | `string` | — |
| `instance_class` | RDS instance class | `string` | — |
| `password_wo` | Master password (write-only) | `string` | — |
| `password_wo_version` | Version counter for password rotation | `number` | — |
| `multi_az` | Enable Multi-AZ | `bool` | `false` |
| `db_name` | Application database name | `string` | `sentinel` |
| `username` | Master database username | `string` | `sentinel` |

## Outputs

| Name | Description |
|---|---|
| `endpoint` | RDS connection endpoint (address:port) |
| `address` | RDS hostname |
| `port` | RDS port |
| `security_group_id` | ID of the RDS security group |
