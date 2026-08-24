resource "aws_s3_bucket" "state" {
  bucket        = var.state_bucket_name
  force_destroy = false
  tags = {
    Name    = "${local.project_name}-terraform-state"
    Purpose = "state-storage"
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      # Uses the AWS-managed alias/aws/s3 key rather than a customer-managed key.
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Persistent zone keeps nameservers stable across workload rebuilds.
resource "aws_route53_zone" "pilotlight" {
  # DNSSEC signing and query logging both need extra infra (KMS key, log group) not justified here.
  #checkov:skip=CKV2_AWS_38,CKV2_AWS_39
  name = local.base_domain

  tags = {
    Name = "${local.project_name}-shared-zone"
  }

  # config.json feeds every root, so validate it here where the zone is created.
  lifecycle {
    precondition {
      condition = can(
        regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", local.base_domain)
      )
      error_message = "config.json base_domain must be a lowercase DNS name with no scheme, port, or trailing dot."
    }

    precondition {
      condition     = length(trimspace(local.project_name)) > 0
      error_message = "config.json project_name must not be empty."
    }
  }
}

# manage/pass role scoping (env-prefix wildcards) lives inside the module now,
# so there's no per-role-name list to keep in sync here. See terraform-ci-iam/locals.tf.
module "terraform_ci_iam" {
  source = "../../modules/terraform-ci-iam"

  project_name     = local.project_name
  github_org       = var.github_org
  github_repo      = var.github_repo
  github_owner_id  = var.github_owner_id
  github_repo_id   = var.github_repo_id
  state_bucket_arn = aws_s3_bucket.state.arn
}
