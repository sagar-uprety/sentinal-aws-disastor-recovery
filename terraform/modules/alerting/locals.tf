locals {
  ecs_service_name        = "${var.project_name}-${var.environment}"
  rds_instance_identifier = "${var.project_name}-${var.environment}"

  # self-scoped so a caller's alarm matches only its own service, even if the region later
  # gains a second one; an explicit deployment_failed_service_arns still wins.
  own_service_arn = format(
    "arn:aws:ecs:%s:%s:service/%s/%s",
    data.aws_region.current.region,
    data.aws_caller_identity.current.account_id,
    var.ecs_cluster_name,
    local.ecs_service_name,
  )
  deployment_failed_service_arns = coalesce(var.deployment_failed_service_arns, [local.own_service_arn])
}
