# GitHub OIDC Module

IAM OpenID Connect provider and role that let GitHub Actions (`app.yml`) authenticate to AWS without long-lived access keys.

## Design Intent

GitHub Actions requests a short-lived OIDC token and exchanges it for temporary AWS credentials via `sts:AssumeRoleWithWebIdentity`. The trust policy requires the exact `production` GitHub environment subject for this repository, so repository identity and environment protection rules both gate assumption. The attached policy is scoped to exactly what `app.yml` needs: push an image to one ECR repository, pass the reviewed regional task and execution roles, register task definition revisions, and update the prod and DR ECS services, with no broader ECS, ECR, or IAM access.

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
| [aws_iam_role.github_actions](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.app_deploy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_dr_ecr_repository_arn"></a> [dr\_ecr\_repository\_arn](#input\_dr\_ecr\_repository\_arn) | ARN of the replicated DR ECR repository checked by application deployments. | `string` | n/a | yes |
| <a name="input_dr_ecs_cluster_arn"></a> [dr\_ecs\_cluster\_arn](#input\_dr\_ecs\_cluster\_arn) | ARN of the DR ECS cluster updated by application deployments. | `string` | n/a | yes |
| <a name="input_dr_ecs_service_arn"></a> [dr\_ecs\_service\_arn](#input\_dr\_ecs\_service\_arn) | ARN of the DR ECS service updated by application deployments. | `string` | n/a | yes |
| <a name="input_dr_ecs_task_execution_role_arn"></a> [dr\_ecs\_task\_execution\_role\_arn](#input\_dr\_ecs\_task\_execution\_role\_arn) | ARN of the DR ECS task execution role passed during task definition registration. | `string` | n/a | yes |
| <a name="input_dr_ecs_task_role_arn"></a> [dr\_ecs\_task\_role\_arn](#input\_dr\_ecs\_task\_role\_arn) | ARN of the DR ECS task role passed during task definition registration. | `string` | n/a | yes |
| <a name="input_ecr_repository_arn"></a> [ecr\_repository\_arn](#input\_ecr\_repository\_arn) | ARN of the ECR repository app.yml pushes images to. | `string` | n/a | yes |
| <a name="input_ecs_cluster_arn"></a> [ecs\_cluster\_arn](#input\_ecs\_cluster\_arn) | ARN of the ECS cluster app.yml deploys to. | `string` | n/a | yes |
| <a name="input_ecs_service_arn"></a> [ecs\_service\_arn](#input\_ecs\_service\_arn) | ARN of the ECS service app.yml updates. | `string` | n/a | yes |
| <a name="input_ecs_task_execution_role_arn"></a> [ecs\_task\_execution\_role\_arn](#input\_ecs\_task\_execution\_role\_arn) | ARN of the ECS task execution role that app.yml must be able to pass when registering a new task definition revision. | `string` | n/a | yes |
| <a name="input_ecs_task_role_arn"></a> [ecs\_task\_role\_arn](#input\_ecs\_task\_role\_arn) | ARN of the ECS application task role that app.yml must be able to pass when registering a new task definition revision. | `string` | n/a | yes |
| <a name="input_environment"></a> [environment](#input\_environment) | Deployment environment name. | `string` | n/a | yes |
| <a name="input_github_oidc_provider_arn"></a> [github\_oidc\_provider\_arn](#input\_github\_oidc\_provider\_arn) | ARN of the shared GitHub Actions OIDC provider created by bootstrap. | `string` | n/a | yes |
| <a name="input_github_org"></a> [github\_org](#input\_github\_org) | GitHub organization or user that owns the repository. | `string` | n/a | yes |
| <a name="input_github_repo"></a> [github\_repo](#input\_github\_repo) | GitHub repository name (without owner). | `string` | n/a | yes |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name for resource naming. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_role_arn"></a> [role\_arn](#output\_role\_arn) | ARN of the IAM role GitHub Actions assumes via OIDC (used as AWS\_ROLE\_ARN in app.yml). |
<!-- END_TF_DOCS -->

## IAM Exceptions

`ecr:GetAuthorizationToken`, `ecs:RegisterTaskDefinition`, and `ecs:DescribeTaskDefinition` use `Resource = "*"`; none of the three support resource-level scoping (ECR auth tokens are account-wide, and task definition registration has no ARN to scope to before the revision exists). Documented exception per Hard Rule 7.
