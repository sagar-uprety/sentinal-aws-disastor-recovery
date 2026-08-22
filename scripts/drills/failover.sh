#!/usr/bin/env bash
# promotes the secondary replica and starts pilot-light compute without switching traffic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=../config.sh
source "$SCRIPT_DIR/../config.sh"
# shellcheck source=drill-lib.sh
source "$SCRIPT_DIR/drill-lib.sh"

readonly SECONDARY_CLUSTER="$SECONDARY_RESOURCE_NAME"
readonly SECONDARY_SERVICE="$SECONDARY_RESOURCE_NAME"
readonly SECONDARY_DB_ID="$SECONDARY_RESOURCE_NAME"
readonly SECONDARY_ALB_NAME="${SECONDARY_RESOURCE_NAME}-alb"
readonly SECONDARY_TARGET_GROUP_NAME="${SECONDARY_RESOURCE_NAME}-tg"
readonly SECONDARY_SSM_ARN_PREFIX="arn:aws:ssm:${SECONDARY_REGION}:"
readonly SECONDARY_ECS_ALARM_NAME="${SECONDARY_RESOURCE_NAME}-ecs-running-tasks"
readonly SECONDARY_ALB_ALARM_NAME="${SECONDARY_RESOURCE_NAME}-alb-healthy-hosts"
readonly RPO_TARGET_SECONDS="${RPO_TARGET_SECONDS:-60}"

if [ "${CONFIRM_FAILOVER:-}" != "YES" ]; then
  echo "error: set CONFIRM_FAILOVER=YES after independently confirming the outage" >&2
  exit 1
fi
require_current_event "outage_confirmed"
require_current_event "primary_link_created_at"

# sets promotion_state to fresh, in_progress, or promoted before mutation.
determine_promotion_state() {
  local db_status replica_source
  read -r db_status replica_source <<<"$(aws rds describe-db-instances \
    --region "$SECONDARY_REGION" \
    --db-instance-identifier "$SECONDARY_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
  promotion_state="fresh"

  # treats a standalone writer as resumable only when this drill invoked promotion.
  if replica_source_is_empty "$replica_source"; then
    require_current_event "failover_invoked"
    if [ -n "$(current_event_ts replica_promoted)" ]; then
      echo "error: current drill already recorded replica_promoted; refusing ambiguous retry" >&2
      exit 1
    fi
    promotion_state="promoted"
    return
  fi

  if [[ "$replica_source" != "$PRIMARY_RESOURCE_NAME" && "$replica_source" != *":db:${PRIMARY_RESOURCE_NAME}" ]]; then
    echo "error: Secondary replica source is $replica_source, expected $PRIMARY_RESOURCE_NAME" >&2
    exit 1
  fi

  # resumes polling because AWS retains the source ARN while promotion is modifying.
  if [ -n "$(current_event_ts failover_invoked)" ]; then
    promotion_state="in_progress"
    return
  fi

  if [ "$db_status" != "available" ]; then
    echo "error: $SECONDARY_DB_ID is not an available read replica; refusing irreversible promotion" >&2
    exit 1
  fi
}

determine_promotion_state

# requires resting secondary compute before promotion starts.
read -r desired_count running_count <<<"$(aws ecs describe-services \
  --region "$SECONDARY_REGION" \
  --cluster "$SECONDARY_CLUSTER" \
  --services "$SECONDARY_SERVICE" \
  --query 'services[0].[desiredCount,runningCount]' --output text)"
if [ "$desired_count" != "0" ] || [ "$running_count" != "0" ]; then
  echo "error: Secondary ECS is not in pilot-light state (desired=$desired_count, running=$running_count)" >&2
  exit 1
fi

# proves immutable image and regional secrets exist before irreversible promotion.
task_definition_json="$(mktemp)"
rendered_task_definition_json="$(mktemp)"
trap 'rm -f "$task_definition_json" "$rendered_task_definition_json"' EXIT
aws ecs describe-task-definition \
  --region "$SECONDARY_REGION" \
  --task-definition "$SECONDARY_SERVICE" \
  --query 'taskDefinition' >"$task_definition_json"

# rejects mutable image tags because secondary must run the exact tested primary artifact.
image_uri="$(jq -r '.containerDefinitions[0].image' "$task_definition_json")"
if [[ "$image_uri" != *@sha256:* ]]; then
  echo "error: Secondary task definition does not use an immutable image digest" >&2
  exit 1
fi
repository="${image_uri%%@*}"
repository="${repository#*/}"
image_digest="${image_uri##*@}"
aws ecr describe-images \
  --region "$SECONDARY_REGION" \
  --repository-name "$repository" \
  --image-ids "imageDigest=$image_digest" \
  --query 'imageDetails[0].imageDigest' --output text >/dev/null

# resolves the regional database password before primary replication is broken.
password_parameter_arn="$(jq -r '.containerDefinitions[0].secrets[] | select(.name == "DB_PASSWORD") | .valueFrom' "$task_definition_json")"
if [[ "$password_parameter_arn" != "$SECONDARY_SSM_ARN_PREFIX"* ]]; then
  echo "error: Secondary task definition does not reference a $SECONDARY_REGION SSM password parameter" >&2
  exit 1
fi
aws ssm get-parameter \
  --region "$SECONDARY_REGION" \
  --name "$password_parameter_arn" \
  --with-decryption \
  --query 'Parameter.Version' --output text >/dev/null

# resolves the regional write token before primary replication is broken.
link_token_parameter_arn="$(jq -r '.containerDefinitions[0].secrets[] | select(.name == "LINK_CREATE_TOKEN") | .valueFrom' "$task_definition_json")"
if [[ "$link_token_parameter_arn" != "$SECONDARY_SSM_ARN_PREFIX"* ]]; then
  echo "error: Secondary task definition does not reference a $SECONDARY_REGION link-token parameter" >&2
  exit 1
fi
aws ssm get-parameter \
  --region "$SECONDARY_REGION" \
  --name "$link_token_parameter_arn" \
  --with-decryption \
  --query 'Parameter.Version' --output text >/dev/null

# captures fresh lag evidence immediately before irreversible promotion.
case "$promotion_state" in
fresh)
  five_minutes_ago="$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
  lag_data="$(aws cloudwatch get-metric-statistics \
    --region "$SECONDARY_REGION" \
    --namespace AWS/RDS \
    --metric-name ReplicaLag \
    --dimensions Name=DBInstanceIdentifier,Value="$SECONDARY_DB_ID" \
    --start-time "$five_minutes_ago" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 60 --statistics Maximum \
    --query 'sort_by(Datapoints, &Timestamp)[-1]' --output json)"
  replica_lag="$(jq -r '.Maximum // empty' <<<"$lag_data")"
  lag_timestamp="$(jq -r '.Timestamp // empty' <<<"$lag_data")"
  if [ -z "$replica_lag" ] || [ "$replica_lag" = "-1" ] || [ -z "$lag_timestamp" ]; then
    echo "error: current ReplicaLag evidence is unavailable; refusing drill promotion" >&2
    exit 1
  fi
  lag_age=$(( $(date -u +%s) - $(to_epoch "$lag_timestamp") ))
  if [ "$lag_age" -gt 180 ]; then
    echo "error: latest ReplicaLag datapoint is ${lag_age}s old" >&2
    exit 1
  fi
  record_event_at "replica_lag_seconds" "$replica_lag"
  record_event_at "replica_lag_timestamp" "$lag_timestamp"
  if ! awk -v lag="$replica_lag" -v target="$RPO_TARGET_SECONDS" 'BEGIN { exit !(lag <= target) }'; then
    if [ "${ALLOW_RPO_TARGET_MISS:-}" != "YES" ]; then
      echo "error: ReplicaLag ${replica_lag}s exceeds ${RPO_TARGET_SECONDS}s; set ALLOW_RPO_TARGET_MISS=YES to accept" >&2
      exit 1
    fi
    log_event "rpo_target_miss_accepted"
  fi

  echo "Promoting replica $SECONDARY_DB_ID in $SECONDARY_REGION..."
  aws rds promote-read-replica --region "$SECONDARY_REGION" --db-instance-identifier "$SECONDARY_DB_ID" >/dev/null
  log_event "failover_invoked"
  ;;
promoted)
  echo "Resuming current drill after verified replica promotion..."
  ;;
in_progress)
  echo "Promotion is still in progress; resuming status polling..."
  ;;
*)
  echo "error: unknown promotion state: $promotion_state" >&2
  exit 1
  ;;
esac

# waits up to 20 minutes for an available standalone writer.
promoted_status=""
promoted_source=""
for _ in {1..120}; do
  read -r promoted_status promoted_source <<<"$(aws rds describe-db-instances \
    --region "$SECONDARY_REGION" \
    --db-instance-identifier "$SECONDARY_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
  if [ "$promoted_status" = "available" ] && replica_source_is_empty "$promoted_source"; then
    break
  fi
  sleep 10
done

read -r promoted_status promoted_source db_endpoint db_port <<<"$(aws rds describe-db-instances \
  --region "$SECONDARY_REGION" \
  --db-instance-identifier "$SECONDARY_DB_ID" \
  --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier,Endpoint.Address,Endpoint.Port]' --output text)"
if [ "$promoted_status" != "available" ] || ! replica_source_is_empty "$promoted_source"; then
  echo "error: promotion did not produce an available standalone database" >&2
  exit 1
fi
log_event "replica_promoted"

# rewrites database coordinates and removes read-only fields before task-definition registration.
jq --arg host "$db_endpoint" --arg port "$db_port" '
  .containerDefinitions[0].environment |= map(
    if .name == "DB_HOST" then .value = $host
    elif .name == "DB_PORT" then .value = $port
    else . end
  )
  | {family, taskRoleArn, executionRoleArn, networkMode, containerDefinitions,
     requiresCompatibilities, cpu, memory, runtimePlatform}
  | with_entries(select(.value != null))
' "$task_definition_json" >"$rendered_task_definition_json"

# starts secondary compute with the promoted writer endpoint and waits for stability.
new_task_definition_arn="$(aws ecs register-task-definition \
  --region "$SECONDARY_REGION" \
  --cli-input-json "file://${rendered_task_definition_json}" \
  --query 'taskDefinition.taskDefinitionArn' --output text)"

aws ecs update-service \
  --region "$SECONDARY_REGION" \
  --cluster "$SECONDARY_CLUSTER" \
  --service "$SECONDARY_SERVICE" \
  --task-definition "$new_task_definition_arn" \
  --desired-count 2 \
  >/dev/null
aws ecs wait services-stable --region "$SECONDARY_REGION" --cluster "$SECONDARY_CLUSTER" --services "$SECONDARY_SERVICE"

# verifies waiter success against explicit desired and running counts.
read -r desired_count running_count <<<"$(aws ecs describe-services \
  --region "$SECONDARY_REGION" \
  --cluster "$SECONDARY_CLUSTER" \
  --services "$SECONDARY_SERVICE" \
  --query 'services[0].[desiredCount,runningCount]' --output text)"
if [ "$desired_count" != "2" ] || [ "$running_count" != "2" ]; then
  echo "error: Secondary service is not stable at 2/2 tasks" >&2
  exit 1
fi

# requires two-AZ task placement before secondary can receive traffic.
read -r -a task_arns <<<"$(aws ecs list-tasks \
  --region "$SECONDARY_REGION" \
  --cluster "$SECONDARY_CLUSTER" \
  --service-name "$SECONDARY_SERVICE" \
  --desired-status RUNNING \
  --query 'taskArns' --output text)"
az_count="$(aws ecs describe-tasks \
  --region "$SECONDARY_REGION" \
  --cluster "$SECONDARY_CLUSTER" \
  --tasks "${task_arns[@]}" \
  --query 'tasks[].availabilityZone' --output json | jq 'unique | length')"
if [ "${#task_arns[@]}" -ne 2 ] || [ "$az_count" -ne 2 ]; then
  echo "error: Secondary tasks are not running across two Availability Zones; do not route traffic" >&2
  exit 1
fi
log_event "secondary_service_stable"

# preserves the existing SNS destination when reactivating secondary alarms.
alert_topic_arn="$(aws cloudwatch describe-alarms \
  --region "$SECONDARY_REGION" \
  --alarm-names "$SECONDARY_ECS_ALARM_NAME" \
  --query 'MetricAlarms[0].AlarmActions[0]' --output text)"
if [ -z "$alert_topic_arn" ] || [ "$alert_topic_arn" = "None" ]; then
  echo "error: missing secondary ECS running-task alarm action" >&2
  exit 1
fi
# activates task-count alerting for serving secondary compute.
aws cloudwatch put-metric-alarm \
  --region "$SECONDARY_REGION" \
  --alarm-name "$SECONDARY_ECS_ALARM_NAME" \
  --alarm-description "ECS running task count is below the active secondary count." \
  --namespace ECS/ContainerInsights \
  --metric-name RunningTaskCount \
  --statistic Minimum \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 2 \
  --comparison-operator LessThanThreshold \
  --treat-missing-data breaching \
  --dimensions "Name=ClusterName,Value=$SECONDARY_CLUSTER" "Name=ServiceName,Value=$SECONDARY_SERVICE" \
  --alarm-actions "$alert_topic_arn" \
  --ok-actions "$alert_topic_arn"
log_event "secondary_task_alarm_activated"

# derives ARN suffixes required by Application ELB metric dimensions.
load_balancer_arn="$(aws elbv2 describe-load-balancers \
  --region "$SECONDARY_REGION" \
  --names "$SECONDARY_ALB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
target_group_arn="$(aws elbv2 describe-target-groups \
  --region "$SECONDARY_REGION" \
  --names "$SECONDARY_TARGET_GROUP_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)"
load_balancer_suffix="${load_balancer_arn#*:loadbalancer/}"
target_group_suffix="${target_group_arn##*:}"

aws cloudwatch put-metric-alarm \
  --region "$SECONDARY_REGION" \
  --alarm-name "$SECONDARY_ALB_ALARM_NAME" \
  --alarm-description "Secondary ALB has fewer than one healthy target while active." \
  --namespace AWS/ApplicationELB \
  --metric-name HealthyHostCount \
  --statistic Minimum \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 1 \
  --comparison-operator LessThanThreshold \
  --treat-missing-data breaching \
  --dimensions "Name=LoadBalancer,Value=$load_balancer_suffix" \
    "Name=TargetGroup,Value=$target_group_suffix" \
  --alarm-actions "$alert_topic_arn" \
  --ok-actions "$alert_topic_arn"
log_event "secondary_alb_alarm_activated"

# requires two healthy secondary targets before application verification.
healthy_count=0
for _ in {1..60}; do
  healthy_count="$(aws elbv2 describe-target-health \
    --region "$SECONDARY_REGION" \
    --target-group-arn "$target_group_arn" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)"
  [ "$healthy_count" = "2" ] && break
  sleep 5
done
if [ "$healthy_count" != "2" ]; then
  echo "error: Secondary has $healthy_count healthy ALB targets, expected 2" >&2
  exit 1
fi
log_event "secondary_targets_healthy"

# proves the promoted database contains every write visible before the outage.
secondary_alb_dns="$(aws elbv2 describe-load-balancers \
  --region "$SECONDARY_REGION" \
  --names "$SECONDARY_ALB_NAME" \
  --query 'LoadBalancers[0].DNSName' --output text)"
require_current_event "primary_link_slugs_before_outage"
primary_slugs_before_outage="$(current_event_ts primary_link_slugs_before_outage)"
missing_slugs="$(require_all_short_links_direct "$WORKLOAD_HOST" "$secondary_alb_dns" "$primary_slugs_before_outage")" || {
  echo "error: Secondary is missing pre-outage links: $missing_slugs; traffic must not be switched" >&2
  exit 1
}
# records wall-clock secondary verification because replicated row timestamps cannot measure data-loss time.
log_event "pre_outage_link_verified_in_secondary"

# proves promoted secondary accepts new writes instead of only serving replicated reads.
secondary_link_slug="secondary-drill-$(date -u +%Y%m%d%H%M%S)"
secondary_link="$(create_short_link_direct "$SECONDARY_REGION" "$WORKLOAD_HOST" "$secondary_alb_dns" "$secondary_link_slug" "https://${SENTRY_HOST}")"
secondary_link_created_at="$(jq -r '.created_at' <<<"$secondary_link")"
record_event_at "secondary_link_slug" "$secondary_link_slug"
record_event_at "secondary_link_created_at" "$secondary_link_created_at"
log_event "secondary_write_verified"
curl --fail --silent --show-error "https://${SENTRY_HOST}/healthz" >/dev/null
log_event "sentry_available_during_failover"

cat <<EOF

Secondary is promoted, healthy, writing, and running two tasks across two AZs.
Traffic has NOT been switched.

Next operator-gated step:
  CONFIRM_TRAFFIC_SWITCH=secondary scripts/drills/switch-traffic.sh secondary
EOF
