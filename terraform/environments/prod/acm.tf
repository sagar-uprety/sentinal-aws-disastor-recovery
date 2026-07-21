locals {
  app_hostname = "sentinel.sagaruprety.com.np"
}

data "aws_route53_zone" "sentinel" {
  name         = "sentinel.sagaruprety.com.np."
  private_zone = false
}

# ACM certificates are regional, so each ALB receives a certificate issued in its own Region.
resource "aws_acm_certificate" "primary" {
  domain_name       = local.app_hostname
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate" "dr" {
  provider = aws.dr

  domain_name       = local.app_hostname
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "certificate_validation" {
  for_each = {
    for dvo in aws_acm_certificate.primary.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.sentinel.zone_id
}

resource "aws_acm_certificate_validation" "primary" {
  certificate_arn         = aws_acm_certificate.primary.arn
  validation_record_fqdns = [for record in aws_route53_record.certificate_validation : record.fqdn]
}

# ACM reuses the validation CNAME for the same FQDN in one AWS account, including across Regions.
resource "aws_acm_certificate_validation" "dr" {
  provider = aws.dr

  certificate_arn         = aws_acm_certificate.dr.arn
  validation_record_fqdns = [for record in aws_route53_record.certificate_validation : record.fqdn]
}
