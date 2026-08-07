#!/usr/bin/env bash
# Runs guarded in-Region HA drills and records recovery evidence.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=drill-lib.sh
source "$SCRIPT_DIR/drill-lib.sh"

REGION="eu-central-1"
CLUSTER="sentinel-aws-dr-prod"
SERVICE="sentinel-aws-dr-prod"
DATABASE="sentinel-aws-dr-prod"
TARGET_GROUP="sentinel-aws-dr-prod-tg"
WORKLOAD_HOST="app.sentinel.sagaruprety.com.np"
MONITOR_HOST="sentinel.sagaruprety.com.np"

if [ "${CONFIRM_HA:-}" != "YES" ]; then
  echo "Set CONFIRM_HA=YES to run a controlled HA drill." >&2
  exit 1
fi

target_group_arn="$(aws elbv2 describe-target-groups \
  --region "$REGION" \
  --names "$TARGET_GROUP" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)"
alb_dns="$(aws elbv2 describe-load-balancers \
  --region "$REGION" \
  --names "sentinel-aws-dr-prod-alb" \
  --query 'LoadBalancers[0].DNSName' --output text)"

task_arns() {
  aws ecs list-tasks \
    --region "$REGION" \
    --cluster "$CLUSTER" \
    --service-name "$SERVICE" \
    --desired-status RUNNING \
    --query 'taskArns' --output text
}

public_health_status() {
  curl -sS -o /dev/null -w '%{http_code}' "https://${WORKLOAD_HOST}/healthz" || true
}

healthy_target_count() {
  aws elbv2 describe-target-health \
    --region "$REGION" \
    --target-group-arn "$target_group_arn" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text
}

task_az_count() {
  local tasks=("$@")
  if [ "${#tasks[@]}" -eq 0 ]; then
    printf '0\n'
    return
  fi
  aws ecs describe-tasks \
    --region "$REGION" \
    --cluster "$CLUSTER" \
    --tasks "${tasks[@]}" \
    --query 'tasks[].availabilityZone' --output json | jq 'unique | length'
}

require_healthy_baseline() {
  local desired running healthy az_count status topology
  local tasks=()
  read -r desired running <<<"$(aws ecs describe-services \
    --region "$REGION" \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --query 'services[0].[desiredCount,runningCount]' --output text)"
  read -r -a tasks <<<"$(task_arns)"
  healthy="$(healthy_target_count)"
  az_count="$(task_az_count "${tasks[@]}")"
  status="$(public_health_status)"
  topology="$(curl -fsS "https://${MONITOR_HOST}/topology" || true)"
  if [ "$desired" != "2" ] || [ "$running" != "2" ] || [ "${#tasks[@]}" -ne 2 ] || [ "$healthy" != "2" ] || [ "$az_count" != "2" ] || [ "$status" != "200" ] || ! jq -e 'any(.regions[]; .region == "eu-central-1" and .database.identifier == "sentinel-aws-dr-prod" and .database.available == true)' >/dev/null <<<"$topology"; then
    echo "ERROR: HA baseline requires ECS 2/2, two task AZs, two healthy targets, and public HTTP 200." >&2
    echo "Observed desired=$desired running=$running tasks=${#tasks[@]} azs=$az_count healthy=$healthy http=$status." >&2
    exit 1
  fi
  log_event "ha_baseline_verified"
}

wait_for_ecs_recovery() {
  local event_prefix="$1" started="$2" desired running healthy az_count status elapsed
  local health_failed=false
  local tasks=()
  for _ in {1..60}; do
    status="$(public_health_status)"
    if ! curl --fail --silent --show-error "https://${MONITOR_HOST}/healthz" >/dev/null; then
      echo "ERROR: isolated monitor became unavailable during $event_prefix recovery." >&2
      return 1
    fi
    if [ "$status" != "200" ]; then
      health_failed=true
    fi
    read -r desired running <<<"$(aws ecs describe-services \
      --region "$REGION" \
      --cluster "$CLUSTER" \
      --services "$SERVICE" \
      --query 'services[0].[desiredCount,runningCount]' --output text)"
    read -r -a tasks <<<"$(task_arns)"
    healthy="$(healthy_target_count)"
    az_count="$(task_az_count "${tasks[@]}")"
    if [ "$desired" = "2" ] && [ "$running" = "2" ] && [ "${#tasks[@]}" -eq 2 ] && [ "$healthy" = "2" ] && [ "$az_count" = "2" ]; then
      elapsed=$(( $(date -u +%s) - started ))
      record_event_at "${event_prefix}_recovery_seconds" "$elapsed"
      if [ "$health_failed" = true ]; then
        echo "ERROR: public /healthz became unavailable during $event_prefix recovery." >&2
        return 1
      fi
      return 0
    fi
    sleep 5
  done
  echo "ERROR: ECS did not recover to two healthy targets across two AZs within five minutes." >&2
  return 1
}

require_healthy_baseline

case "${1:-}" in
task)
  read -r task _ <<<"$(task_arns)"
  if [ -z "$task" ]; then
    echo "No running Sentinel task found." >&2
    exit 1
  fi
  record_event_at "ha_task_stopped" "$task"
  started="$(date -u +%s)"
  aws ecs stop-task --region "$REGION" --cluster "$CLUSTER" --task "$task" --reason "controlled-ha-task-drill" >/dev/null
  wait_for_ecs_recovery "ha_task" "$started"
  running_after="$(task_arns)"
  if [[ " $running_after " == *" $task "* ]]; then
    echo "ERROR: stopped task still appears in the running set." >&2
    exit 1
  fi
  log_event "ha_task_replacement_verified"
  echo "Stopped task was replaced with continuous public health and two-AZ placement."
  ;;

az)
  az="${2:-}"
  if [ -z "$az" ]; then
    echo "Usage: CONFIRM_HA=YES $0 az <eu-central-1a|eu-central-1b>" >&2
    exit 1
  fi
  read -r -a tasks <<<"$(task_arns)"
  task_details="$(aws ecs describe-tasks --region "$REGION" --cluster "$CLUSTER" --tasks "${tasks[@]}" --output json)"
  selected="$(jq -r --arg az "$az" '.tasks[] | select(.availabilityZone == $az) | .taskArn' <<<"$task_details")"
  survivor_count="$(jq -r --arg az "$az" '[.tasks[] | select(.availabilityZone != $az)] | length' <<<"$task_details")"
  if [ -z "$selected" ] || [ "$survivor_count" -lt 1 ]; then
    echo "ERROR: observed task placement cannot demonstrate surviving-AZ service for $az." >&2
    exit 1
  fi
  record_event_at "ha_az_injection" "$az"
  started="$(date -u +%s)"
  while IFS= read -r task; do
    aws ecs stop-task --region "$REGION" --cluster "$CLUSTER" --task "$task" --reason "controlled-ha-az-drill" >/dev/null
  done <<<"$selected"
  wait_for_ecs_recovery "ha_az" "$started"
  running_after=" $(task_arns) "
  while IFS= read -r task; do
    if [[ "$running_after" == *" $task "* ]]; then
      echo "ERROR: task stopped in $az still appears in the running set." >&2
      exit 1
    fi
  done <<<"$selected"
  log_event "ha_az_recovery_verified"
  echo "A task survived outside $az; ECS restored continuous public health and two-AZ placement."
  ;;

db)
  # Forces a real Multi-AZ failover on the production database -- materially
  # higher blast radius (a brief write-path interruption on prod) than
  # stopping one ECS task or one AZ's worth of tasks, so it gets its own
  # confirmation on top of CONFIRM_HA, matching the per-action gating used
  # in failback.sh and switch-traffic.sh.
  if [ "${CONFIRM_HA_DB_FAILOVER:-}" != "YES" ]; then
    echo "Set CONFIRM_HA_DB_FAILOVER=YES to force a real Multi-AZ RDS failover on production." >&2
    exit 1
  fi
  known_slug="ha-db-$(date -u +%Y%m%d%H%M%S)"
  create_short_link_direct "$REGION" "$WORKLOAD_HOST" "$alb_dns" "$known_slug" "https://${MONITOR_HOST}" >/dev/null
  record_event_at "ha_db_known_link_before" "$known_slug"
  read -r multi_az writer_az standby_az <<<"$(aws rds describe-db-instances \
    --region "$REGION" \
    --db-instance-identifier "$DATABASE" \
    --query 'DBInstances[0].[MultiAZ,AvailabilityZone,SecondaryAvailabilityZone]' --output text)"
  if [ "$multi_az" != "True" ] || [ -z "$standby_az" ] || [ "$standby_az" = "None" ]; then
    echo "ERROR: database is not a verified Multi-AZ instance." >&2
    exit 1
  fi
  record_event_at "ha_db_writer_before" "$writer_az"
  record_event_at "ha_db_standby_before" "$standby_az"
  log_event "ha_db_failover_started"
  started="$(date -u +%s)"
  aws rds reboot-db-instance --region "$REGION" --db-instance-identifier "$DATABASE" --force-failover >/dev/null

  health_interruptions=0
  recovered=false
  new_writer_az="$writer_az"
  new_standby_az="$standby_az"
  for _ in {1..120}; do
    status="$(public_health_status)"
    if [ "$status" != "200" ]; then
      health_interruptions=$((health_interruptions + 1))
    fi
    read -r db_status new_writer_az new_standby_az <<<"$(aws rds describe-db-instances \
      --region "$REGION" \
      --db-instance-identifier "$DATABASE" \
      --query 'DBInstances[0].[DBInstanceStatus,AvailabilityZone,SecondaryAvailabilityZone]' --output text)"
    if [ "$db_status" = "available" ] && [ "$new_writer_az" != "$writer_az" ] && [ "$status" = "200" ]; then
      recovered=true
      break
    fi
    sleep 5
  done
  if [ "$recovered" != true ]; then
    echo "ERROR: database writer and public health did not recover after forced failover." >&2
    exit 1
  fi
  if ! require_short_link_direct "$WORKLOAD_HOST" "$alb_dns" "$known_slug"; then
    echo "ERROR: known pre-failover link is missing after Multi-AZ recovery." >&2
    exit 1
  fi
  record_event_at "ha_db_known_link_after" "$known_slug"
  elapsed=$(( $(date -u +%s) - started ))
  record_event_at "ha_db_recovery_seconds" "$elapsed"
  record_event_at "ha_db_health_interruption_samples" "$health_interruptions"
  record_event_at "ha_db_writer_after" "$new_writer_az"
  record_event_at "ha_db_standby_after" "$new_standby_az"
  log_event "ha_db_failover_verified"
  echo "RDS writer moved from $writer_az to $new_writer_az in ${elapsed}s; /healthz missed $health_interruptions five-second samples."
  ;;

*)
  echo "Usage: CONFIRM_HA=YES $0 {task|az <availability-zone>|db}" >&2
  echo "       db additionally requires CONFIRM_HA_DB_FAILOVER=YES (forces a real Multi-AZ RDS failover)." >&2
  exit 1
  ;;
esac
