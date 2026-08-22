# Terraform CI IAM Module

The GitHub OIDC provider plus the two roles that let GitHub Actions run Terraform itself: a broad `PowerUserAccess`-backed apply role (scoped IAM management on top, since `PowerUserAccess` excludes IAM) for the production environment, and a read-only plan role for pull requests. Distinct from the `github-oidc` module, which builds per-environment app-deploy roles (ECR push, ECS update) that trust this module's OIDC provider.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11, < 2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.60.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_iam_openid_connect_provider.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_role.terraform_github_apply](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.terraform_github_plan](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.terraform_workload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.terraform_plan_read_only](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.terraform_power_user](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_github_org"></a> [github\_org](#input\_github\_org) | GitHub organization or user that owns the repository. | `string` | n/a | yes |
| <a name="input_github_repo"></a> [github\_repo](#input\_github\_repo) | GitHub repository name (without owner). | `string` | n/a | yes |
| <a name="input_manageable_role_suffixes"></a> [manageable\_role\_suffixes](#input\_manageable\_role\_suffixes) | Role suffixes (after "${project\_name}-{env}-") this CI role may create/update/delete. | `list(string)` | <pre>[<br/>  "github-actions",<br/>  "ecs-task-exec",<br/>  "ecs-task",<br/>  "vpc-flow-logs",<br/>  "rds-monitoring"<br/>]</pre> | no |
| <a name="input_passable_role_suffixes"></a> [passable\_role\_suffixes](#input\_passable\_role\_suffixes) | Role suffixes (after "${project\_name}-{env}-") this CI role may PassRole to ECS. | `list(string)` | <pre>[<br/>  "ecs-task-exec",<br/>  "ecs-task",<br/>  "vpc-flow-logs",<br/>  "rds-monitoring"<br/>]</pre> | no |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name for resource naming. | `string` | n/a | yes |
| <a name="input_workload_environments"></a> [workload\_environments](#input\_workload\_environments) | Environment names whose IAM roles this CI role may manage. | `list(string)` | <pre>[<br/>  "prod",<br/>  "dr",<br/>  "monitoring"<br/>]</pre> | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_oidc_provider_arn"></a> [oidc\_provider\_arn](#output\_oidc\_provider\_arn) | ARN of the GitHub Actions OIDC provider, consumed by every environment's app-deploy-iam module call. |
| <a name="output_terraform_apply_role_arn"></a> [terraform\_apply\_role\_arn](#output\_terraform\_apply\_role\_arn) | ARN of the role GitHub Actions assumes to apply Terraform. |
| <a name="output_terraform_plan_role_arn"></a> [terraform\_plan\_role\_arn](#output\_terraform\_plan\_role\_arn) | ARN of the role GitHub Actions assumes for read-only PR plans. |
<!-- END_TF_DOCS -->
