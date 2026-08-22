#!/usr/bin/env bash
# Maps changed Terraform paths to the root modules that import them.
set -euo pipefail

monitoring=false
primary=false
secondary=false

for path in "$@"; do
  case "$path" in
    terraform/environments/monitoring/* | terraform/modules/ecs-sentry/*)
      monitoring=true
      ;;
    terraform/environments/primary/*)
      primary=true
      ;;
    terraform/environments/secondary/* | terraform/modules/route53-failover/*)
      secondary=true
      ;;
    terraform/modules/app-deploy-iam/* | terraform/modules/ecr/*)
      monitoring=true
      primary=true
      ;;
    terraform/modules/ecs-url-shortener/* | terraform/modules/rds/*)
      primary=true
      secondary=true
      ;;
    terraform/modules/acm-cert/* | terraform/modules/alb/* | terraform/modules/alerting/* | terraform/modules/vpc/*)
      monitoring=true
      primary=true
      secondary=true
      ;;
  esac
done

json=""
$monitoring && json='"monitoring"'
$primary && json+="${json:+,}\"primary\""
$secondary && json+="${json:+,}\"secondary\""
printf '[%s]\n' "$json"
