#!/usr/bin/env bash
# Sourced by both the plan and apply jobs so their -var flags per target never drift apart.

# DEPLOY_SERVICE/CREATE_ARC come from workflow_dispatch inputs; unset (PR-triggered plans) defaults to steady-state.
build_plan_args() {
  local deploy_service="${DEPLOY_SERVICE:-true}"
  local create_arc="${CREATE_ARC:-}"
  plan_args=()
  case "$TF_TARGET" in
    # primary always wants multi_az; deploy_service gates the two-phase bootstrap apply.
    primary) plan_args+=("-var=deploy_service=$deploy_service" "-var=multi_az=true") ;;
    monitoring) plan_args+=("-var=deploy_service=$deploy_service") ;;
    # create_arc only applies to secondary, and only when explicitly set.
    secondary) [ -n "$create_arc" ] && plan_args+=("-var=create_arc=$create_arc") ;;
  esac
}
