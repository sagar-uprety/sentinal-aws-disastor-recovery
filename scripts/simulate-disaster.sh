#!/usr/bin/env bash
# Simulates a controlled primary application outage without changing routing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/drill-lib.sh"

PROD_REGION="eu-central-1"
DR_REGION="eu-west-1"
CLUSTER="sentinel-aws-dr-prod"
SERVICE="sentinel-aws-dr-prod"
DR_CLUSTER="sentinel-aws-dr-dr"
DR_SERVICE="sentinel-aws-dr-dr"
DR_DB_ID="sentinel-aws-dr-dr"
TARGET_GROUP="sentinel-aws-dr-prod-tg"
LOAD_BALANCER="sentinel-aws-dr-prod-alb"
STATUS_HOST="status.sentinel.sagaruprety.com.np"
RPO_TARGET_URL="${RPO_TARGET_URL:-https://${STATUS_HOST}}"

if [ "${CONFIRM_DISASTER:-}" != "YES" ]; then
  echo "Set CONFIRM_DISASTER=YES to start the controlled outage." >&2
  exit 1
fi

prod_service="$(aws ecs describe-services \
  --region "$PROD_REGION" \
  --cluster "$CLUSTER" \
  --services "$SERVICE" \
  --query 'services[0].{desired:desiredCount,running:runningCount}' --output json)"
original_desired="$(jq -r '.desired' <<<"$prod_service")"
running_count="$(jq -r '.running' <<<"$prod_service")"
if [ "$original_desired" -lt 1 ] || [ "$running_count" -lt 1 ]; then
  echo "ERROR: primary ECS service is not serving traffic; refusing to simulate another outage." >&2
  exit 1
fi

dr_desired="$(aws ecs describe-services \
  --region "$DR_REGION" \
  --cluster "$DR_CLUSTER" \
  --services "$DR_SERVICE" \
  --query 'services[0].desiredCount' --output text)"
if [ "$dr_desired" != "0" ]; then
  echo "ERROR: DR desired count is $dr_desired, expected pilot-light count 0." >&2
  exit 1
fi

read -r dr_status dr_source <<<"$(aws rds describe-db-instances \
  --region "$DR_REGION" \
  --db-instance-identifier "$DR_DB_ID" \
  --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
if [ "$dr_status" != "available" ] || [ -z "$dr_source" ] || [ "$dr_source" = "None" ]; then
  echo "ERROR: DR database is not an available read replica." >&2
  exit 1
fi

target_group_arn="$(aws elbv2 describe-target-groups \
  --region "$PROD_REGION" \
  --names "$TARGET_GROUP" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)"
alb_dns="$(aws elbv2 describe-load-balancers \
  --region "$PROD_REGION" \
  --names "$LOAD_BALANCER" \
  --query 'LoadBalancers[0].DNSName' --output text)"

status_body="$(curl -fsS --connect-to "${STATUS_HOST}:443:${alb_dns}:443" "https://${STATUS_HOST}/status")"
primary_last_check="$(jq -r --arg target "$RPO_TARGET_URL" '[.[] | select(.url == $target) | .last_checked] | max // empty' <<<"$status_body")"
if [ -z "$primary_last_check" ]; then
  echo "ERROR: no primary check exists for RPO target $RPO_TARGET_URL." >&2
  exit 1
fi

log_event "drill_started"
record_event_at "primary_last_check" "$primary_last_check"

aws ecs update-service \
  --region "$PROD_REGION" \
  --cluster "$CLUSTER" \
  --service "$SERVICE" \
  --desired-count 0 \
  >/dev/null
log_event "disaster_declared"

echo "Primary desired count set to 0. Waiting for a confirmed user-visible outage..."
for _ in {1..24}; do
  status="$(curl -sS -o /dev/null -w '%{http_code}' --connect-to "${STATUS_HOST}:443:${alb_dns}:443" "https://${STATUS_HOST}/healthz" || true)"
  healthy_count="$(aws elbv2 describe-target-health \
    --region "$PROD_REGION" \
    --target-group-arn "$target_group_arn" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)"

  if [ "$status" = "503" ] && [ "$healthy_count" = "0" ]; then
    log_event "outage_confirmed"
    echo "Primary outage confirmed. Run CONFIRM_FAILOVER=YES scripts/failover.sh."
    exit 0
  fi
  sleep 5
done

log_event "outage_confirmation_failed"
echo "Outage confirmation failed; restoring primary desired count to $original_desired." >&2
aws ecs update-service \
  --region "$PROD_REGION" \
  --cluster "$CLUSTER" \
  --service "$SERVICE" \
  --desired-count "$original_desired" \
  >/dev/null
aws ecs wait services-stable --region "$PROD_REGION" --cluster "$CLUSTER" --services "$SERVICE"
log_event "primary_restored_after_failed_simulation"
exit 1
