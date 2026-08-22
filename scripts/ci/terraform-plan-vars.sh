#!/usr/bin/env bash
# keeps plan and apply jobs aligned on target-specific Terraform variables.

# populates global plan_args while preserving steady-state defaults for non-dispatch runs.
build_plan_args() {
  local deploy_service="${DEPLOY_SERVICE:-true}"
  local create_arc="${CREATE_ARC:-}"
  plan_args=()
  case "$TF_TARGET" in
    primary) plan_args+=("-var=deploy_service=$deploy_service" "-var=multi_az=true") ;;
    monitoring) plan_args+=("-var=deploy_service=$deploy_service") ;;
    secondary) [ -n "$create_arc" ] && plan_args+=("-var=create_arc=$create_arc") ;;
  esac
}
