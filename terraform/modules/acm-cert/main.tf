# ACM certificates are regional; this module issues one in whatever region its caller's provider targets.
resource "aws_acm_certificate" "cert" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  # Validates the replacement cert before the old one is destroyed, so the
  # live HTTPS listener is never briefly left with no valid certificate.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  # empty map when false, so no records get created for the reuse case (e.g. secondary).
  for_each = var.create_validation_records ? {
    # one map entry per domain the cert covers (just one today) -- keyed by domain so for_each
    # below makes one record per domain, scaling automatically if this cert ever covers more than one.
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true # in case a matching record already exists from another cert request for the same domain
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60 # seconds
  type            = each.value.type
  zone_id         = var.route53_zone_id
}

resource "aws_acm_certificate_validation" "cert" {
  certificate_arn = aws_acm_certificate.cert.arn
  # lists the FQDNs of the records we create; null when we create none (secondary), relying on
  # primary's CNAME for this domain instead.
  validation_record_fqdns = (
    var.create_validation_records
    ? [for record in aws_route53_record.validation : record.fqdn]
    : null
  )
}
