resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_144:cross-region replication not needed for terraform state; state is regenerable and versioned
  bucket        = var.state_bucket_name
  force_destroy = false
  tags = {
    Name    = "${var.project_name}-terraform-state"
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
      # Uses the AWS-managed alias/aws/s3 key (no per-key monthly fee) rather
      # than a customer-managed key.
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

resource "aws_s3_bucket_notification" "state" {
  bucket      = aws_s3_bucket.state.id
  eventbridge = true
}

resource "aws_s3_bucket" "logs" {
  #checkov:skip=CKV_AWS_144:log-sink bucket; access logs don't need cross-region DR replication
  #checkov:skip=CKV_AWS_18:this bucket is itself the access-log destination; chaining log buckets recursively isn't practical
  #checkov:skip=CKV_AWS_145:S3 server access log delivery only supports SSE-S3 (AES256); AWS does not support delivering access logs to an SSE-KMS bucket
  bucket        = "${var.state_bucket_name}-access-logs"
  force_destroy = true
  tags = {
    Name    = "${var.project_name}-terraform-state-access-logs"
    Purpose = "state-storage"
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_notification" "logs" {
  bucket      = aws_s3_bucket.logs.id
  eventbridge = true
}

resource "aws_s3_bucket_logging" "state" {
  bucket        = aws_s3_bucket.state.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "state-bucket-access-logs/"
}

# Not read by any backend "s3" block (those use native S3 locking via
# use_lockfile = true); kept only as a documented compatibility fallback.
resource "aws_dynamodb_table" "lock" {
  #checkov:skip=CKV_AWS_119:uses the AWS-owned default key (free) rather than a customer-managed key
  name         = "${var.project_name}-terraform-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  # Uses the AWS-owned default key (free) rather than a customer-managed key.
  server_side_encryption {
    enabled = true
  }

  tags = {
    Purpose = "state-storage"
  }
}
