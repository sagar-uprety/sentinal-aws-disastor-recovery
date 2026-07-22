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
