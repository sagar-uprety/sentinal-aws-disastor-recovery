# The ARC cluster is billed per cluster-hour while it exists ($2.50/hour at
# last check). Provision only when the project owner has explicitly
# confirmed the drill and its cost; destroy after recording. See
# terraform/modules/route53-failover/README.md.
# When ARC is off, a simple A alias routes the apex to prod ALB directly.

data "aws_route53_zone" "sentinel" {
  name         = "${local.app_hostname}."
  private_zone = false
}

# Detection-only HTTP health checks for evidence and alarming. Not wired to
# any DNS record and not part of the traffic-switch path — only ARC's
# RECOVERY_CONTROL health checks gate DNS. failure_threshold=3 (consecutive
# failures, ~90s at the default 30s interval) avoids reacting to one
# transient failure, per section 4.5. Always active, regardless of ARC state.
resource "aws_route53_health_check" "primary_detection" {
  type              = "HTTP"
  fqdn              = data.aws_lb.prod.dns_name
  port              = 80
  resource_path     = "/healthz"
  failure_threshold = 3
  request_interval  = 30

  tags = {
    Name = "${local.project_name}-primary-detection"
  }
}

resource "aws_route53_health_check" "dr_detection" {
  type              = "HTTP"
  fqdn              = module.alb.alb_dns_name
  port              = 80
  resource_path     = "/healthz"
  failure_threshold = 3
  request_interval  = 30

  tags = {
    Name = "${local.project_name}-dr-detection"
  }
}

module "route53_failover" {
  source = "../../modules/route53-failover"
  count  = var.create_arc ? 1 : 0

  project_name    = local.project_name
  route53_zone_id = data.aws_route53_zone.sentinel.zone_id
  record_name     = local.app_hostname

  primary_alb_dns_name = data.aws_lb.prod.dns_name
  primary_alb_zone_id  = data.aws_lb.prod.zone_id

  dr_alb_dns_name = module.alb.alb_dns_name
  dr_alb_zone_id  = module.alb.alb_zone_id
}

# Simple A alias to prod when ARC is not provisioned.
resource "aws_route53_record" "apex" {
  count   = var.create_arc ? 0 : 1
  zone_id = data.aws_route53_zone.sentinel.zone_id
  name    = local.app_hostname
  type    = "A"

  alias {
    name                   = data.aws_lb.prod.dns_name
    zone_id                = data.aws_lb.prod.zone_id
    evaluate_target_health = true
  }
}
