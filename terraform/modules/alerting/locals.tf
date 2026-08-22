locals {
  ecs_service_name        = "${var.project_name}-${var.environment}"
  rds_instance_identifier = "${var.project_name}-${var.environment}"

  # self-scoped by default so every caller's deployment-failure alarm only ever
  # matches its own service, with no risk of forgetting to wire this up when a
  # region later gains a second ECS service. An explicit deployment_failed_service_arns
  # still wins, for the rare case of watching more than just this one service.
  own_service_arn = format(
    "arn:aws:ecs:%s:%s:service/%s/%s",
    data.aws_region.current.region,
    data.aws_caller_identity.current.account_id,
    var.ecs_cluster_name,
    local.ecs_service_name,
  )
  deployment_failed_service_arns = coalesce(var.deployment_failed_service_arns, [local.own_service_arn])
}
