# ECS Service Module

Fargate cluster with a single service, ARM64 runtime, circuit breaker, and SSM-secured database credentials.

## Design Intent

Tasks run in private application subnets behind the ALB security group. The task execution role receives narrowly scoped `ssm:GetParameters` on one regional SecureString ARN and `kms:Decrypt` for the region-local KMS key. The service ships with a deployment circuit breaker (`enable = true`, `rollback = true`) using the provider-supported defaults. `deploy_service = false` allows the first M2 phase to create supporting resources before an image is available.

**Fargate platform:** `operating_system_family = "LINUX"`, `cpu_architecture = "ARM64"` (Graviton). Pinned explicitly rather than relying on `LATEST`.

## Inputs

| Name | Description | Type | Default |
|---|---|---|---|
| `project_name` | Project name | `string` | — |
| `environment` | Deployment environment | `string` | — |
| `vpc_id` | VPC ID | `string` | — |
| `app_subnet_ids` | Application private subnet IDs | `list(string)` | — |
| `alb_security_group_id` | ALB security group ID | `string` | — |
| `target_group_arn` | ALB target group ARN | `string` | — |
| `image_uri` | ECR image URI with digest | `string` | — |
| `db_endpoint` | RDS host:port | `string` | — |
| `db_name` | Database name | `string` | — |
| `db_user` | Database username | `string` | — |
| `db_password_ssm_arn` | SSM SecureString parameter ARN | `string` | — |
| `self_url` | Public status page URL for self-check | `string` | `""` |
| `deploy_service` | Create the ECS service | `bool` | `true` |
| `desired_count` | Number of tasks | `number` | `2` |
| `task_cpu` | vCPU units per task | `number` | `256` |
| `task_memory` | Memory MiB per task | `number` | `512` |
| `container_port` | Container port | `number` | `8080` |
| `otel_endpoint` | OTLP HTTP endpoint for the OTel Collector | `string` | `http://localhost:4318` |

## Outputs

| Name | Description |
|---|---|
| `cluster_name` | ECS cluster name |
| `security_group_id` | ECS tasks security group ID |
| `task_execution_role_arn` | Task execution IAM role ARN |

## IAM Exceptions

`kms:Decrypt` uses `Resource = "*"` scoped to the region-local KMS key ARN prefix. The SSM key ARN cannot be known before the parameter exists. This exception is documented per Hard Rule 7.
