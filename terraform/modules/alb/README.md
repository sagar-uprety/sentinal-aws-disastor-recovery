# ALB Module

Application Load Balancer on HTTP port 80.

## Design Intent

Public HTTP traffic on port 80 is forwarded to ECS tasks on port 8080. The app no longer exposes `/metrics` publicly — all telemetry flows through OTLP push to an internal OTel Collector. Health checks target `/healthz`.

## Inputs

| Name | Description | Type | Default |
|---|---|---|---|
| `project_name` | Project name for resource naming | `string` | — |
| `environment` | Deployment environment name | `string` | — |
| `vpc_id` | ID of the VPC | `string` | — |
| `public_subnet_ids` | IDs of the public subnets | `list(string)` | — |

## Outputs

| Name | Description |
|---|---|
| `alb_arn` | ARN of the Application Load Balancer |
| `alb_dns_name` | DNS name of the Application Load Balancer |
| `target_group_arn` | ARN of the ALB target group |
| `security_group_id` | ID of the ALB security group |
| `alb_arn_suffix` | ARN suffix of the ALB, for CloudWatch alarm dimensions |
| `target_group_arn_suffix` | ARN suffix of the target group, for CloudWatch alarm dimensions |
