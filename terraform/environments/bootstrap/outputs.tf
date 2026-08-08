output "state_bucket" {
  description = "Name of the S3 bucket that stores Terraform state."
  value       = aws_s3_bucket.state.id
}

output "lock_table" {
  description = "Name of the DynamoDB compatibility lock table."
  value       = aws_dynamodb_table.lock.name
}

output "github_oidc_provider_arn" {
  description = "ARN of the shared GitHub Actions OIDC provider."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "terraform_github_actions_role_arn" {
  description = "ARN of the GitHub Actions role that provisions Pilotlight infrastructure."
  value       = aws_iam_role.terraform_github_actions.arn
}

output "terraform_github_plan_role_arn" {
  description = "ARN of the read-only GitHub Actions role used for pull-request Terraform plans."
  value       = aws_iam_role.terraform_github_plan.arn
}

output "route53_zone_id" {
  description = "Persistent hosted zone ID for pilotlight.sagaruprety.com.np."
  value       = aws_route53_zone.pilotlight.zone_id
}

output "route53_zone_name_servers" {
  description = "Nameservers delegated once from the Cloudflare-managed parent zone."
  value       = aws_route53_zone.pilotlight.name_servers
}
