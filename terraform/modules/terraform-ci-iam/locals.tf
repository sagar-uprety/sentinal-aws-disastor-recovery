locals {
  iam_role_arn_prefix = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role"

  # exact names (env x suffix), not a bare "-*": a bare wildcard would let this
  # role CreateRole/PutRolePolicy under any name in the prefix, not just the
  # known role kinds -- the CreateRole+PutRolePolicy combo is a standard IAM
  # privilege-escalation path, so this stays as narrow as pass_role_arns.
  manage_role_arns = [
    for pair in setproduct(var.workload_environments, var.manageable_role_suffixes) :
    "${local.iam_role_arn_prefix}/${var.project_name}-${pair[0]}-${pair[1]}"
  ]

  # exact names (env x suffix), not a wildcard: PassRole hands a role to an AWS service, so
  # this stays scoped to the specific role kinds it's actually meant for, not "anything named right".
  pass_role_arns = [
    for pair in setproduct(var.workload_environments, var.passable_role_suffixes) :
    "${local.iam_role_arn_prefix}/${var.project_name}-${pair[0]}-${pair[1]}"
  ]
}
