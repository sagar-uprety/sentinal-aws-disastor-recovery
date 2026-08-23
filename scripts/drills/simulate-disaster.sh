#!/usr/bin/env bash
# simulates a controlled primary application outage without changing routing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=../config.sh
source "$SCRIPT_DIR/../config.sh"
# shellcheck source=drill-lib.sh
source "$SCRIPT_DIR/drill-lib.sh"

readonly CLUSTER="$PRIMARY_RESOURCE_NAME"
readonly SERVICE="$PRIMARY_RESOURCE_NAME"
readonly SECONDARY_CLUSTER="$SECONDARY_RESOURCE_NAME"
readonly SECONDARY_SERVICE="$SECONDARY_RESOURCE_NAME"
readonly SECONDARY_DB_ID="$SECONDARY_RESOURCE_NAME"
readonly TARGET_GROUP="${PRIMARY_RESOURCE_NAME}-tg"
readonly LOAD_BALANCER="${PRIMARY_RESOURCE_NAME}-alb"

# ==== PRECHECKS ====
if [ "${CONFIRM_DISASTER:-}" != "YES" ]; then
  echo "error: set CONFIRM_DISASTER=YES to start the controlled outage" >&2
  exit 1
fi

# must be proven up first, or surviving the outage afterwards proves nothing.
curl --fail --silent --show-error "https://${SENTRY_HOST}/healthz" >/dev/null

# a service already at zero would let a pre-existing incident be recorded as drill evidence.
primary_service="$(aws ecs describe-services \
  --region "$PRIMARY_REGION" \
  --cluster "$CLUSTER" \
  --services "$SERVICE" \
  --query 'services[0].{desired:desiredCount,running:runningCount}' --output json)"
original_desired="$(jq -r '.desired' <<<"$primary_service")"
running_count="$(jq -r '.running' <<<"$primary_service")"
if [ "$original_desired" -lt 1 ] || [ "$running_count" -lt 1 ]; then
  echo "error: primary ECS service is not serving traffic; refusing another outage" >&2
  exit 1
fi

# requires resting secondary compute so previous drill state cannot contaminate evidence.
secondary_desired="$(aws ecs describe-services \
  --region "$SECONDARY_REGION" \
  --cluster "$SECONDARY_CLUSTER" \
  --services "$SECONDARY_SERVICE" \
  --query 'services[0].desiredCount' --output text)"
if [ "$secondary_desired" != "0" ]; then
  echo "error: Secondary desired count is $secondary_desired, expected pilot-light count 0" >&2
  exit 1
fi

# without a live replica of this primary, scaling to zero is a real outage, not a drill.
read -r secondary_status secondary_replicates_from _ <<<"$(db_topology "$SECONDARY_REGION" "$SECONDARY_DB_ID")"
if [ "$secondary_status" != "available" ] || has_no_replication_source "$secondary_replicates_from" ||
  [[ "$secondary_replicates_from" != "$PRIMARY_RESOURCE_NAME" && "$secondary_replicates_from" != *":db:${PRIMARY_RESOURCE_NAME}" ]]; then
  echo "error: Secondary database is not an available replica of $PRIMARY_RESOURCE_NAME" >&2
  exit 1
fi

target_group_arn="$(target_group_arn_for "$PRIMARY_REGION" "$TARGET_GROUP")"
alb_dns="$(alb_dns_name "$PRIMARY_REGION" "$LOAD_BALANCER")"

# ==== MAIN TASK: inject a controlled, evidence-backed primary outage ====
# opens a new log segment; later lookups read back only to this marker.
log_event "drill_started"

pre_outage_slug="pre-drill-$(date -u +%Y%m%d%H%M%S)"
pre_outage_link="$(create_short_link_direct "$PRIMARY_REGION" "$WORKLOAD_HOST" "$alb_dns" "$pre_outage_slug" "https://${SENTRY_HOST}")"
primary_link_created_at="$(jq -r '.created_at' <<<"$pre_outage_link")"
record_event_at "pre_outage_link_slug" "$pre_outage_slug"
record_event_at "primary_link_created_at" "$primary_link_created_at"

# the full set, so failover proves every pre-outage row survived rather than sampling one.
primary_slugs_before_outage="$(list_short_links_direct "$WORKLOAD_HOST" "$alb_dns" | jq -r '[.[].slug] | join(",")')"
record_event_at "primary_link_slugs_before_outage" "$primary_slugs_before_outage"

# injects a user-visible outage by scaling primary compute to zero.
aws ecs update-service \
  --region "$PRIMARY_REGION" \
  --cluster "$CLUSTER" \
  --service "$SERVICE" \
  --desired-count 0 \
  >/dev/null
log_event "disaster_declared"

# ==== POSTCHECKS ====
# the ALB returns 503 only with no healthy target, so both agreeing rules out a blip.
echo "Primary desired count set to 0. Waiting for a confirmed user-visible outage..."
for _ in {1..24}; do
  status="$(curl -sS -o /dev/null -w '%{http_code}' --connect-to "${WORKLOAD_HOST}:443:${alb_dns}:443" "https://${WORKLOAD_HOST}/healthz" || true)"
  healthy_count="$(healthy_target_count "$PRIMARY_REGION" "$target_group_arn")"

  if [ "$status" = "503" ] && [ "$healthy_count" = "0" ]; then
    curl --fail --silent --show-error "https://${SENTRY_HOST}/healthz" >/dev/null
    log_event "sentry_available_during_outage"
    log_event "outage_confirmed"
    echo "Primary outage confirmed. Run CONFIRM_FAILOVER=YES scripts/drills/failover.sh."
    exit 0
  fi
  sleep 5
done

# an unprovable outage must not leave primary sitting at zero.
log_event "outage_confirmation_failed"
echo "error: outage confirmation failed; restoring primary desired count to $original_desired" >&2
aws ecs update-service \
  --region "$PRIMARY_REGION" \
  --cluster "$CLUSTER" \
  --service "$SERVICE" \
  --desired-count "$original_desired" \
  >/dev/null
aws ecs wait services-stable --region "$PRIMARY_REGION" --cluster "$CLUSTER" --services "$SERVICE"
log_event "primary_restored_after_failed_simulation"
exit 1
