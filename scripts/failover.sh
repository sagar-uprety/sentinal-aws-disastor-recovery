#!/usr/bin/env bash
# Promotes the DR replica and starts pilot-light compute without switching traffic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=drill-lib.sh
source "$SCRIPT_DIR/drill-lib.sh"

DR_REGION="eu-west-1"
DR_CLUSTER="pilotlight-dr"
DR_SERVICE="pilotlight-dr"
DR_DB_ID="pilotlight-dr"
DR_ECS_ALARM_NAME="pilotlight-dr-ecs-running-tasks"
DR_ALB_ALARM_NAME="pilotlight-dr-alb-healthy-hosts"
WORKLOAD_HOST="shortener.pilotlight.sagaruprety.com.np"
MONITOR_HOST="monitor.pilotlight.sagaruprety.com.np"
RPO_TARGET_SECONDS="${RPO_TARGET_SECONDS:-60}"

if [ "${CONFIRM_FAILOVER:-}" != "YES" ]; then
  echo "Set CONFIRM_FAILOVER=YES after independently confirming the outage." >&2
  exit 1
fi
require_current_event "outage_confirmed"
require_current_event "primary_link_created_at"

read -r db_status replica_source <<<"$(aws rds describe-db-instances \
  --region "$DR_REGION" \
  --db-instance-identifier "$DR_DB_ID" \
  --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
resume_promoted=false
promotion_in_progress=false
if [ -z "$replica_source" ] || [ "$replica_source" = "None" ]; then
  require_current_event "failover_invoked"
  if [ -n "$(current_event_ts replica_promoted)" ]; then
    echo "ERROR: current drill already recorded replica_promoted; refusing an ambiguous retry." >&2
    exit 1
  fi
  resume_promoted=true
elif [ -n "$(current_event_ts failover_invoked)" ]; then
  # promote-read-replica was already called earlier in this drill; the
  # instance just has not finished settling (AWS keeps the source ARN set
  # while status is "modifying" mid-promotion). Resume by polling instead
  # of erroring out or calling promote-read-replica a second time.
  echo "Promotion already invoked earlier in this drill (status=$db_status); resuming poll..."
  promotion_in_progress=true
elif [ "$db_status" != "available" ]; then
  echo "ERROR: $DR_DB_ID is not an available read replica; refusing irreversible promotion." >&2
  exit 1
else
  log_event "failover_invoked"
fi

read -r desired_count running_count <<<"$(aws ecs describe-services \
  --region "$DR_REGION" \
  --cluster "$DR_CLUSTER" \
  --services "$DR_SERVICE" \
  --query 'services[0].[desiredCount,runningCount]' --output text)"
if [ "$desired_count" != "0" ] || [ "$running_count" != "0" ]; then
  echo "ERROR: DR ECS is not in pilot-light state (desired=$desired_count, running=$running_count)." >&2
  exit 1
fi

task_definition_json="$(mktemp)"
rendered_task_definition_json="$(mktemp)"
trap 'rm -f "$task_definition_json" "$rendered_task_definition_json"' EXIT
aws ecs describe-task-definition \
  --region "$DR_REGION" \
  --task-definition "$DR_SERVICE" \
  --query 'taskDefinition' >"$task_definition_json"

image_uri="$(jq -r '.containerDefinitions[0].image' "$task_definition_json")"
if [[ "$image_uri" != *@sha256:* ]]; then
  echo "ERROR: DR task definition does not use an immutable image digest." >&2
  exit 1
fi
repository="${image_uri%%@*}"
repository="${repository#*/}"
image_digest="${image_uri##*@}"
aws ecr describe-images \
  --region "$DR_REGION" \
  --repository-name "$repository" \
  --image-ids "imageDigest=$image_digest" \
  --query 'imageDetails[0].imageDigest' --output text >/dev/null

password_parameter_arn="$(jq -r '.containerDefinitions[0].secrets[] | select(.name == "DB_PASSWORD") | .valueFrom' "$task_definition_json")"
if [[ "$password_parameter_arn" != arn:aws:ssm:eu-west-1:* ]]; then
  echo "ERROR: DR task definition does not reference an eu-west-1 SSM password parameter." >&2
  exit 1
fi
aws ssm get-parameter \
  --region "$DR_REGION" \
  --name "$password_parameter_arn" \
  --with-decryption \
  --query 'Parameter.Version' --output text >/dev/null

link_token_parameter_arn="$(jq -r '.containerDefinitions[0].secrets[] | select(.name == "LINK_CREATE_TOKEN") | .valueFrom' "$task_definition_json")"
if [[ "$link_token_parameter_arn" != arn:aws:ssm:eu-west-1:* ]]; then
  echo "ERROR: DR task definition does not reference an eu-west-1 link-token parameter." >&2
  exit 1
fi

if [ "$resume_promoted" = false ] && [ "$promotion_in_progress" = false ]; then
  five_minutes_ago="$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
  lag_data="$(aws cloudwatch get-metric-statistics \
    --region "$DR_REGION" \
    --namespace AWS/RDS \
    --metric-name ReplicaLag \
    --dimensions Name=DBInstanceIdentifier,Value="$DR_DB_ID" \
    --start-time "$five_minutes_ago" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 60 --statistics Maximum \
    --query 'sort_by(Datapoints, &Timestamp)[-1]' --output json)"
  replica_lag="$(jq -r '.Maximum // empty' <<<"$lag_data")"
  lag_timestamp="$(jq -r '.Timestamp // empty' <<<"$lag_data")"
  if [ -z "$replica_lag" ] || [ "$replica_lag" = "-1" ] || [ -z "$lag_timestamp" ]; then
    echo "ERROR: current ReplicaLag evidence is unavailable; refusing drill promotion." >&2
    exit 1
  fi
  lag_age=$(( $(date -u +%s) - $(to_epoch "$lag_timestamp") ))
  if [ "$lag_age" -gt 180 ]; then
    echo "ERROR: latest ReplicaLag datapoint is ${lag_age}s old." >&2
    exit 1
  fi
  record_event_at "replica_lag_seconds" "$replica_lag"
  record_event_at "replica_lag_timestamp" "$lag_timestamp"
  if ! awk -v lag="$replica_lag" -v target="$RPO_TARGET_SECONDS" 'BEGIN { exit !(lag <= target) }'; then
    if [ "${ALLOW_RPO_TARGET_MISS:-}" != "YES" ]; then
      echo "ERROR: ReplicaLag ${replica_lag}s exceeds ${RPO_TARGET_SECONDS}s. Set ALLOW_RPO_TARGET_MISS=YES only to record an intentional target miss." >&2
      exit 1
    fi
    log_event "rpo_target_miss_accepted"
  fi

  echo "Promoting replica $DR_DB_ID in $DR_REGION..."
  aws rds promote-read-replica --region "$DR_REGION" --db-instance-identifier "$DR_DB_ID" >/dev/null
elif [ "$resume_promoted" = true ]; then
  echo "Resuming current drill after verified replica promotion..."
fi

promoted_status=""
promoted_source=""
for _ in {1..120}; do
  read -r promoted_status promoted_source <<<"$(aws rds describe-db-instances \
    --region "$DR_REGION" \
    --db-instance-identifier "$DR_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
  if [ "$promoted_status" = "available" ] && { [ -z "$promoted_source" ] || [ "$promoted_source" = "None" ]; }; then
    break
  fi
  sleep 10
done

read -r promoted_status promoted_source db_endpoint db_port <<<"$(aws rds describe-db-instances \
  --region "$DR_REGION" \
  --db-instance-identifier "$DR_DB_ID" \
  --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier,Endpoint.Address,Endpoint.Port]' --output text)"
if [ "$promoted_status" != "available" ] || { [ -n "$promoted_source" ] && [ "$promoted_source" != "None" ]; }; then
  echo "ERROR: promotion did not produce an available standalone database." >&2
  exit 1
fi
log_event "replica_promoted"

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

new_task_definition_arn="$(aws ecs register-task-definition \
  --region "$DR_REGION" \
  --cli-input-json "file://${rendered_task_definition_json}" \
  --query 'taskDefinition.taskDefinitionArn' --output text)"

aws ecs update-service \
  --region "$DR_REGION" \
  --cluster "$DR_CLUSTER" \
  --service "$DR_SERVICE" \
  --task-definition "$new_task_definition_arn" \
  --desired-count 2 \
  >/dev/null
aws ecs wait services-stable --region "$DR_REGION" --cluster "$DR_CLUSTER" --services "$DR_SERVICE"

read -r desired_count running_count <<<"$(aws ecs describe-services \
  --region "$DR_REGION" \
  --cluster "$DR_CLUSTER" \
  --services "$DR_SERVICE" \
  --query 'services[0].[desiredCount,runningCount]' --output text)"
if [ "$desired_count" != "2" ] || [ "$running_count" != "2" ]; then
  echo "ERROR: DR service is not stable at 2/2 tasks." >&2
  exit 1
fi

read -r -a task_arns <<<"$(aws ecs list-tasks \
  --region "$DR_REGION" \
  --cluster "$DR_CLUSTER" \
  --service-name "$DR_SERVICE" \
  --desired-status RUNNING \
  --query 'taskArns' --output text)"
az_count="$(aws ecs describe-tasks \
  --region "$DR_REGION" \
  --cluster "$DR_CLUSTER" \
  --tasks "${task_arns[@]}" \
  --query 'tasks[].availabilityZone' --output json | jq 'unique | length')"
if [ "${#task_arns[@]}" -ne 2 ] || [ "$az_count" -ne 2 ]; then
  echo "ERROR: DR tasks are not running across two Availability Zones; do not route traffic." >&2
  exit 1
fi
log_event "dr_service_stable"

alert_topic_arn="$(aws cloudwatch describe-alarms \
  --region "$DR_REGION" \
  --alarm-names "$DR_ECS_ALARM_NAME" \
  --query 'MetricAlarms[0].AlarmActions[0]' --output text)"
if [ -z "$alert_topic_arn" ] || [ "$alert_topic_arn" = "None" ]; then
  echo "ERROR: missing DR ECS running-task alarm action." >&2
  exit 1
fi
aws cloudwatch put-metric-alarm \
  --region "$DR_REGION" \
  --alarm-name "$DR_ECS_ALARM_NAME" \
  --alarm-description "ECS running task count is below the active DR count." \
  --namespace ECS/ContainerInsights \
  --metric-name RunningTaskCount \
  --statistic Minimum \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 2 \
  --comparison-operator LessThanThreshold \
  --treat-missing-data breaching \
  --dimensions "Name=ClusterName,Value=$DR_CLUSTER" "Name=ServiceName,Value=$DR_SERVICE" \
  --alarm-actions "$alert_topic_arn" \
  --ok-actions "$alert_topic_arn"
log_event "dr_task_alarm_activated"

load_balancer_arn="$(aws elbv2 describe-load-balancers \
  --region "$DR_REGION" \
  --names "pilotlight-dr-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
target_group_arn="$(aws elbv2 describe-target-groups \
  --region "$DR_REGION" \
  --names "pilotlight-dr-tg" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)"
load_balancer_suffix="${load_balancer_arn#*:loadbalancer/}"
target_group_suffix="${target_group_arn##*:}"

aws cloudwatch put-metric-alarm \
  --region "$DR_REGION" \
  --alarm-name "$DR_ALB_ALARM_NAME" \
  --alarm-description "DR ALB has fewer than one healthy target while active." \
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
log_event "dr_alb_alarm_activated"

healthy_count=0
for _ in {1..60}; do
  healthy_count="$(aws elbv2 describe-target-health \
    --region "$DR_REGION" \
    --target-group-arn "$target_group_arn" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)"
  [ "$healthy_count" = "2" ] && break
  sleep 5
done
if [ "$healthy_count" != "2" ]; then
  echo "ERROR: DR has $healthy_count healthy ALB targets, expected 2." >&2
  exit 1
fi
log_event "dr_targets_healthy"

dr_alb_dns="$(aws elbv2 describe-load-balancers \
  --region "$DR_REGION" \
  --names "pilotlight-dr-alb" \
  --query 'LoadBalancers[0].DNSName' --output text)"
require_current_event "primary_link_slugs_before_outage"
primary_slugs_before_outage="$(current_event_ts primary_link_slugs_before_outage)"
missing_slugs="$(require_all_short_links_direct "$WORKLOAD_HOST" "$dr_alb_dns" "$primary_slugs_before_outage")" || {
  echo "ERROR: DR is missing links present on primary before the outage: $missing_slugs; traffic must not be switched." >&2
  exit 1
}
# Real DR-side observation, not a copy of primary's timestamp: replicated
# rows keep the same created_at on both sides by definition, which cannot
# measure elapsed data-loss time. This event's own timestamp (from
# log_event) is what's real: the wall-clock moment DR was confirmed to
# already hold every link that existed on primary before the outage.
log_event "pre_outage_link_verified_in_dr"

dr_link_slug="dr-drill-$(date -u +%Y%m%d%H%M%S)"
dr_link="$(create_short_link_direct "$DR_REGION" "$WORKLOAD_HOST" "$dr_alb_dns" "$dr_link_slug" "https://${MONITOR_HOST}")"
dr_link_created_at="$(jq -r '.created_at' <<<"$dr_link")"
record_event_at "dr_link_slug" "$dr_link_slug"
record_event_at "dr_link_created_at" "$dr_link_created_at"
log_event "dr_write_verified"
curl --fail --silent --show-error "https://${MONITOR_HOST}/healthz" >/dev/null
log_event "monitor_available_during_failover"

cat <<EOF

DR is promoted, healthy, writing, and running two tasks across two AZs.
Traffic has NOT been switched.

Next operator-gated step:
  CONFIRM_TRAFFIC_SWITCH=DR scripts/switch-traffic.sh dr
EOF
