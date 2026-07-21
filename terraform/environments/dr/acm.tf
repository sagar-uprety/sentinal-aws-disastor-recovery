resource "aws_acm_certificate" "dr" {
  domain_name       = local.app_hostname
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# ACM reuses the account-level validation CNAME already managed by prod.
resource "aws_acm_certificate_validation" "dr" {
  certificate_arn = aws_acm_certificate.dr.arn
}

resource "aws_acm_certificate" "legacy" {
  domain_name       = "status.sentinel.sagaruprety.com.np"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Complete the interrupted cross-state ownership transfer without replacing the issued certificate.
import {
  to = aws_acm_certificate.dr
  id = "arn:aws:acm:eu-west-1:926883320788:certificate/5bf57dad-8e1a-4598-8b99-dec4e9c6ea25"
}

# Retain the old certificate in state until the DR listener migration is verified.
import {
  to = aws_acm_certificate.legacy
  id = "arn:aws:acm:eu-west-1:926883320788:certificate/f1cf4834-19d3-41e7-ab1d-6620bfef4a02"
}
