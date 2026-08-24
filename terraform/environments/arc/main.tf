data "aws_route53_zone" "pilotlight" {
  name         = "${local.base_domain}."
  private_zone = false
}

data "aws_lb" "primary" {
  provider = aws.primary
  name     = "${local.project_name}-primary-alb"
}

data "aws_lb" "secondary" {
  provider = aws.secondary
  name     = "${local.project_name}-secondary-alb"
}

# Independent of primary and secondary's own lifecycle, matching AWS's own reference
# architecture for ARC: one centralized failover stack, not owned by either region it
# arbitrates between. Requires both ALBs to exist, so this applies only after primary and
# secondary do; that's fine, since ARC is provisioned only for the duration of a drill, by
# which point both are long since deployed. The at-rest baseline record lives in primary
# instead, so ordinary operation never depends on this stack existing.
module "route53_failover" {
  source = "../../modules/route53-failover"
  count  = local.cfg.create_arc ? 1 : 0

  project_name    = local.project_name
  route53_zone_id = data.aws_route53_zone.pilotlight.zone_id
  record_name     = local.app_hostname

  primary_alb_dns_name = data.aws_lb.primary.dns_name
  primary_alb_zone_id  = data.aws_lb.primary.zone_id

  secondary_alb_dns_name = data.aws_lb.secondary.dns_name
  secondary_alb_zone_id  = data.aws_lb.secondary.zone_id
}
