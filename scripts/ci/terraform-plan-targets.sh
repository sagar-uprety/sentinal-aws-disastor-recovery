#!/usr/bin/env bash
# Maps changed Terraform paths to the root modules that import them.
set -euo pipefail

monitoring=false
primary=false
secondary=false

for path in "$@"; do
  case "$path" in
    # Own root, or a module only that root consumes.
    terraform/environments/monitoring/* | terraform/modules/ecs-sentry/*)
      monitoring=true
      ;;
    terraform/environments/primary/*)
      primary=true
      ;;
    terraform/environments/secondary/* | terraform/modules/route53-failover/*)
      secondary=true
      ;;
    # Shared by monitoring + primary (both run an ECS service pulled from an ECR repo).
    terraform/modules/app-deploy-iam/* | terraform/modules/ecr/*)
      monitoring=true
      primary=true
      ;;
    # Shared by primary + secondary (the url-shortener workload and its database).
    terraform/modules/ecs-url-shortener/* | terraform/modules/rds/*)
      primary=true
      secondary=true
      ;;
    # Shared by all three roots (networking, load balancing, TLS, alerting).
    terraform/modules/acm-cert/* | terraform/modules/alb/* | terraform/modules/alerting/* | terraform/modules/vpc/*)
      monitoring=true
      primary=true
      secondary=true
      ;;
    # terraform-ci-iam/bootstrap fall through on purpose: bootstrap creates this workflow's own CI role, so it can't be planned through this workflow, and is covered separately by infrastructure-quality.yml.
  esac
done

# builds a JSON array of the roots that need to be planned, e.g. ["monitoring","primary"]
json=""
$monitoring && json='"monitoring"'
$primary && json+="${json:+,}\"primary\""
$secondary && json+="${json:+,}\"secondary\""
printf '[%s]\n' "$json"
