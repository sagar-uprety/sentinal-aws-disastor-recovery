#!/usr/bin/env bash
# Promotes the DR replica and starts pilot-light compute without switching traffic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/drill-lib.sh"

DR_REGION="eu-west-1"
DR_CLUSTER="sentinel-aws-dr-dr"
DR_SERVICE="sentinel-aws-dr-dr"
DR_DB_ID="sentinel-aws-dr-dr"
DR_ECS_ALARM_NAME="sentinel-aws-dr-dr-ecs-running-tasks"
DR_ALB_ALARM_NAME="sentinel-aws-dr-dr-alb-healthy-hosts"
STATUS_HOST="sentinel.sagaruprety.com.np"
RPO_TARGET_URL="${RPO_TARGET_URL:-https://${STATUS_HOST}}"
RPO_TARGET_SECONDS="${RPO_TARGET_SECONDS:-60}"

if [ "${CONFIRM_FAILOVER:-}" != "YES" ]; then
  echo "Set CONFIRM_FAILOVER=YES after independently confirming the outage." >&2
  exit 1
fi
require_current_event "outage_confirmed"
outage_ts="$(current_event_ts outage_confirmed)"
log_event "failover_invoked"

read -r db_status replica_source <<<"$(aws rds describe-db-instances \
  --region "$DR_REGION" \
  --db-instance-identifier "$DR_DB_ID" \
  --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
if [ "$db_status" != "available" ] || [ -z "$replica_source" ] || [ "$replica_source" = "None" ]; then
  echo "ERROR: $DR_DB_ID is not an available read replica; refusing irreversible promotion." >&2
  exit 1
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
aws rds wait db-instance-available --region "$DR_REGION" --db-instance-identifier "$DR_DB_ID"

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
  --names "sentinel-aws-dr-dr-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
target_group_arn="$(aws elbv2 describe-target-groups \
  --region "$DR_REGION" \
  --names "sentinel-aws-dr-dr-tg" \
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
  --names "sentinel-aws-dr-dr-alb" \
  --query 'LoadBalancers[0].DNSName' --output text)"
write_verification_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_verified=false
for _ in {1..18}; do
  status_body="$(curl -fsS --connect-to "${STATUS_HOST}:443:${dr_alb_dns}:443" "https://${STATUS_HOST}/status" || true)"
  if jq -e --arg started "$write_verification_started" --arg target "$RPO_TARGET_URL" '
    type == "array" and
    ([.[] | select(.url == $target) | .last_checked | select(type == "string")] | max) > $started
  ' >/dev/null <<<"$status_body"; then
    dr_known_row="$(jq -r --arg target "$RPO_TARGET_URL" '[.[] | select(.url == $target) | .last_checked | select(type == "string")] | max' <<<"$status_body")"
    record_event_at "dr_known_row" "$dr_known_row"
    log_event "dr_write_verified"
    write_verified=true
    break
  fi
  sleep 5
done
if [ "$write_verified" != true ]; then
  echo "ERROR: DR did not persist a fresh check row; traffic must not be switched." >&2
  exit 1
fi

encoded_target="$(jq -rn --arg value "$RPO_TARGET_URL" '$value | @uri')"
history_body="$(curl -fsS --connect-to "${STATUS_HOST}:443:${dr_alb_dns}:443" "https://${STATUS_HOST}/history?target=${encoded_target}&limit=500")"
dr_pre_outage_last_check="$(jq -r --arg cutoff "$outage_ts" '[.[] | select(.checked_at <= $cutoff) | .checked_at] | max // empty' <<<"$history_body")"
if [ -z "$dr_pre_outage_last_check" ]; then
  echo "ERROR: DR history has no pre-outage row for $RPO_TARGET_URL; RPO cannot be measured." >&2
  exit 1
fi
record_event_at "dr_pre_outage_last_check" "$dr_pre_outage_last_check"

cat <<EOF

DR is promoted, healthy, writing, and running two tasks across two AZs.
Traffic has NOT been switched.

Next operator-gated step:
  CONFIRM_TRAFFIC_SWITCH=DR scripts/switch-traffic.sh dr
EOF
