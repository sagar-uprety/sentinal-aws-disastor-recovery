# The ARC cluster is billed per cluster-hour while it exists ($2.50/hour at
# last check). Provision only when the project owner has explicitly
# confirmed the drill and its cost; destroy after recording. See
# terraform/modules/route53-failover/README.md.
module "route53_failover" {
  source = "../../modules/route53-failover"

  project_name    = local.project_name
  route53_zone_id = data.terraform_remote_state.prod.outputs.route53_zone_id
  record_name     = "sentinel.sagaruprety.com.np"

  primary_alb_dns_name = data.terraform_remote_state.prod.outputs.alb_dns_name
  primary_alb_zone_id  = data.terraform_remote_state.prod.outputs.alb_zone_id

  dr_alb_dns_name = module.alb.alb_dns_name
  dr_alb_zone_id  = module.alb.alb_zone_id
}
