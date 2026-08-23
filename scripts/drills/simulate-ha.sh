#!/usr/bin/env bash
# runs guarded in-region HA drills and records recovery evidence.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=../config.sh
source "$SCRIPT_DIR/../config.sh"
# shellcheck source=drill-lib.sh
source "$SCRIPT_DIR/drill-lib.sh"

readonly REGION="$PRIMARY_REGION"
readonly CLUSTER="$PRIMARY_RESOURCE_NAME"
readonly SERVICE="$PRIMARY_RESOURCE_NAME"
readonly DATABASE="$PRIMARY_RESOURCE_NAME"
readonly TARGET_GROUP="${PRIMARY_RESOURCE_NAME}-tg"
readonly LOAD_BALANCER="${PRIMARY_RESOURCE_NAME}-alb"

if [ "${CONFIRM_HA:-}" != "YES" ]; then
  echo "error: set CONFIRM_HA=YES to run a controlled HA drill" >&2
  exit 1
fi

target_group_arn="$(aws elbv2 describe-target-groups \
  --region "$REGION" \
  --names "$TARGET_GROUP" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)"
alb_dns="$(aws elbv2 describe-load-balancers \
  --region "$REGION" \
  --names "$LOAD_BALANCER" \
  --query 'LoadBalancers[0].DNSName' --output text)"

# returns running task ARNs used by baseline and replacement checks.
task_arns() {
  aws ecs list-tasks \
    --region "$REGION" \
    --cluster "$CLUSTER" \
    --service-name "$SERVICE" \
    --desired-status RUNNING \
    --query 'taskArns' --output text
}

# converts transient curl errors into observable non-200 health samples.
public_health_status() {
  curl -sS -o /dev/null -w '%{http_code}' "https://${WORKLOAD_HOST}/healthz" || true
}

# reads ALB target health independently from ECS service counters.
healthy_target_count() {
  aws elbv2 describe-target-health \
    --region "$REGION" \
    --target-group-arn "$target_group_arn" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text
}

# counts distinct task AZs so two tasks in one AZ cannot pass the baseline.
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

# combines ECS, ALB, public HTTP, and sentry topology into one start gate.
require_healthy_baseline() {
  local desired running healthy az_count status topology topology_ok
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
  topology="$(curl -fsS "https://${SENTRY_HOST}/topology" || true)"
  if jq -e --arg region "$REGION" --arg database "$DATABASE" 'any(.regions[]; .region == $region and .database.identifier == $database and .database.available == true)' >/dev/null <<<"$topology"; then
    topology_ok=true
  else
    topology_ok=false
  fi
  if [ "$desired" != "2" ] ||
     [ "$running" != "2" ] ||
     [ "${#tasks[@]}" -ne 2 ] ||
     [ "$healthy" != "2" ] ||
     [ "$az_count" != "2" ] ||
     [ "$status" != "200" ] ||
     [ "$topology_ok" != "true" ]; then
    echo "error: HA baseline requires ECS 2/2, two task AZs, two healthy targets, and HTTP 200" >&2
    echo "       observed desired=$desired running=$running tasks=${#tasks[@]} azs=$az_count healthy=$healthy http=$status" >&2
    exit 1
  fi
  log_event "ha_baseline_verified"
}

# waits for full two-AZ recovery while remembering any public-health interruption.
wait_for_ecs_recovery() {
  local event_prefix="$1" started="$2" desired running healthy az_count status elapsed
  local health_failed=false
  local tasks=()
  for _ in {1..60}; do
    status="$(public_health_status)"
    if ! curl --fail --silent --show-error "https://${SENTRY_HOST}/healthz" >/dev/null; then
      echo "error: isolated sentry became unavailable during $event_prefix recovery" >&2
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
        echo "error: public /healthz became unavailable during $event_prefix recovery" >&2
        return 1
      fi
      return 0
    fi
    sleep 5
  done
  echo "error: ECS did not recover to two healthy targets across two AZs within five minutes" >&2
  return 1
}

# establishes a healthy two-AZ baseline before measuring recovery.
require_healthy_baseline

case "${1:-}" in
# stops one task to verify ECS replacement without public-health loss.
task)
  read -r task _ <<<"$(task_arns)"
  if [ -z "$task" ]; then
    echo "error: no running workload task found" >&2
    exit 1
  fi
  record_event_at "ha_task_stopped" "$task"
  started="$(date -u +%s)"
  aws ecs stop-task --region "$REGION" --cluster "$CLUSTER" --task "$task" --reason "controlled-ha-task-drill" >/dev/null
  wait_for_ecs_recovery "ha_task" "$started"
  running_after="$(task_arns)"
  if [[ " $running_after " == *" $task "* ]]; then
    echo "error: stopped task still appears in the running set" >&2
    exit 1
  fi
  log_event "ha_task_replacement_verified"
  echo "Stopped task was replaced with continuous public health and two-AZ placement."
  ;;

# stops tasks in one AZ to verify surviving-AZ service and ECS replacement.
az)
  az="${2:-}"
  if [ -z "$az" ]; then
    echo "usage: CONFIRM_HA=YES $0 az <${PRIMARY_REGION}a|${PRIMARY_REGION}b>" >&2
    exit 1
  fi
  # requires a task outside the target AZ to prove surviving-AZ service.
  read -r -a tasks <<<"$(task_arns)"
  task_details="$(aws ecs describe-tasks --region "$REGION" --cluster "$CLUSTER" --tasks "${tasks[@]}" --output json)"
  selected="$(jq -r --arg az "$az" '.tasks[] | select(.availabilityZone == $az) | .taskArn' <<<"$task_details")"
  survivor_count="$(jq -r --arg az "$az" '[.tasks[] | select(.availabilityZone != $az)] | length' <<<"$task_details")"
  if [ -z "$selected" ] || [ "$survivor_count" -lt 1 ]; then
    echo "error: task placement cannot demonstrate surviving-AZ service for $az" >&2
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
      echo "error: task stopped in $az still appears in the running set" >&2
      exit 1
    fi
  done <<<"$selected"
  log_event "ha_az_recovery_verified"
  echo "A task survived outside $az; ECS restored continuous public health and two-AZ placement."
  ;;

db)
  # requires separate confirmation because forced RDS failover can briefly interrupt production writes.
  if [ "${CONFIRM_HA_DB_FAILOVER:-}" != "YES" ]; then
    echo "error: set CONFIRM_HA_DB_FAILOVER=YES to force production RDS failover" >&2
    exit 1
  fi
  # requires a real standby before requesting forced database failover.
  read -r multi_az writer_az standby_az <<<"$(aws rds describe-db-instances \
    --region "$REGION" \
    --db-instance-identifier "$DATABASE" \
    --query 'DBInstances[0].[MultiAZ,AvailabilityZone,SecondaryAvailabilityZone]' --output text)"
  if [ "$multi_az" != "True" ] || [ -z "$standby_az" ] || [ "$standby_az" = "None" ]; then
    echo "error: database is not a verified Multi-AZ instance" >&2
    exit 1
  fi

  known_slug="ha-db-$(date -u +%Y%m%d%H%M%S)"
  create_short_link_direct "$REGION" "$WORKLOAD_HOST" "$alb_dns" "$known_slug" "https://${SENTRY_HOST}" >/dev/null
  record_event_at "ha_db_known_link_before" "$known_slug"
  record_event_at "ha_db_writer_before" "$writer_az"
  record_event_at "ha_db_standby_before" "$standby_az"
  log_event "ha_db_failover_started"
  started="$(date -u +%s)"
  aws rds reboot-db-instance --region "$REGION" --db-instance-identifier "$DATABASE" --force-failover >/dev/null

  # samples workload health until RDS reports a different available writer AZ.
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
    echo "error: database writer and public health did not recover after forced failover" >&2
    exit 1
  fi

  # verifies the known pre-failover row survived the writer transition.
  if ! require_short_link_direct "$WORKLOAD_HOST" "$alb_dns" "$known_slug"; then
    echo "error: known pre-failover link is missing after Multi-AZ recovery" >&2
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
  echo "usage: CONFIRM_HA=YES $0 {task|az <availability-zone>|db}" >&2
  echo "       db additionally requires CONFIRM_HA_DB_FAILOVER=YES" >&2
  exit 1
  ;;
esac
