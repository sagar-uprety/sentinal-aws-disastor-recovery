# ECR Module

Private Docker registry with immutable tags and automatic lifecycle cleanup.

## Design Intent

The repository stores the Sentinel container image. `IMMUTABLE` tag mutability prevents accidental overwrites, and the lifecycle policy keeps only the last 10 images. Scan-on-push is enabled for vulnerability visibility. `force_delete = true` allows teardown without manual image cleanup.

## Inputs

| Name | Description | Type | Default |
|---|---|---|---|
| `project_name` | Project name for resource naming | `string` | — |
| `environment` | Deployment environment name | `string` | — |

## Outputs

| Name | Description |
|---|---|
| `repository_url` | URL of the ECR repository |
| `repository_arn` | ARN of the ECR repository |
