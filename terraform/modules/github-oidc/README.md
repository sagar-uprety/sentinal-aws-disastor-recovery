# GitHub OIDC Module

IAM OpenID Connect provider and role that let GitHub Actions (`app.yml`) authenticate to AWS without long-lived access keys.

## Design Intent

GitHub Actions requests a short-lived OIDC token scoped to this repository and exchanges it for temporary AWS credentials via `sts:AssumeRoleWithWebIdentity`. The trust policy's `sub` condition restricts assumption to `repo:${github_org}/${github_repo}:*`, so no other repository or fork can assume the role. The attached policy is scoped to exactly what `app.yml` needs: push an image to one ECR repository, register a new task definition revision, and update one ECS service, no broader ECS, ECR, or IAM access.

## Inputs

| Name | Description | Type | Default |
|---|---|---|---|
| `project_name` | Project name | `string` | — |
| `environment` | Deployment environment | `string` | — |
| `github_org` | GitHub org or user | `string` | — |
| `github_repo` | GitHub repository name | `string` | — |
| `ecr_repository_arn` | ECR repository ARN to push images to | `string` | — |
| `ecs_cluster_arn` | ECS cluster ARN to deploy to | `string` | — |
| `ecs_service_arn` | ECS service ARN to update | `string` | — |
| `ecs_task_execution_role_arn` | Task execution role ARN, passed when registering a new task definition | `string` | — |

## Outputs

| Name | Description |
|---|---|
| `role_arn` | IAM role ARN GitHub Actions assumes (set as the `AWS_ROLE_ARN` secret/var for `app.yml`) |

## IAM Exceptions

`ecr:GetAuthorizationToken`, `ecs:RegisterTaskDefinition`, and `ecs:DescribeTaskDefinition` use `Resource = "*"`; none of the three support resource-level scoping (ECR auth tokens are account-wide, and task definition registration has no ARN to scope to before the revision exists). Documented exception per Hard Rule 7.
