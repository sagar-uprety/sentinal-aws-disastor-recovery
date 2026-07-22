# The ARC cluster is billed per cluster-hour while it exists ($2.50/hour at
# last check). Provision only when the project owner has explicitly
# confirmed the drill and its cost; destroy after recording. See
# terraform/modules/route53-failover/README.md.

data "aws_route53_zone" "sentinel" {
  name         = "${local.app_hostname}."
  private_zone = false
}

module "route53_failover" {
  source = "../../modules/route53-failover"

  project_name    = local.project_name
  route53_zone_id = data.aws_route53_zone.sentinel.zone_id
  record_name     = local.app_hostname

  primary_alb_dns_name = data.aws_lb.prod.dns_name
  primary_alb_zone_id  = data.aws_lb.prod.zone_id

  dr_alb_dns_name = module.alb.alb_dns_name
  dr_alb_zone_id  = module.alb.alb_zone_id
}
