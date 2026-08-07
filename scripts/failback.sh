#!/usr/bin/env bash
# Runs guarded failback operations while Terraform mutations stay in protected GitHub Actions jobs.
# Assumes the active AWS CLI credentials have permission for the requested recovery operation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=drill-lib.sh
source "$SCRIPT_DIR/drill-lib.sh"

PROD_REGION="eu-central-1"
DR_REGION="eu-west-1"
PROD_DB_ID="sentinel-aws-dr-prod"
DR_DB_ID="sentinel-aws-dr-dr"
PROD_CLUSTER="sentinel-aws-dr-prod"
PROD_SERVICE="sentinel-aws-dr-prod"
DR_CLUSTER="sentinel-aws-dr-dr"
DR_SERVICE="sentinel-aws-dr-dr"
WORKLOAD_HOST="app.sentinel.sagaruprety.com.np"
MONITOR_HOST="sentinel.sagaruprety.com.np"
FAILBACK_LAG_TARGET_SECONDS="${FAILBACK_LAG_TARGET_SECONDS:-300}"

latest_replica_lag_json() {
  local region="$1" database="$2" start
  start="$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
  aws cloudwatch get-metric-statistics \
    --region "$region" \
    --namespace AWS/RDS \
    --metric-name ReplicaLag \
    --dimensions Name=DBInstanceIdentifier,Value="$database" \
    --start-time "$start" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 60 --statistics Maximum \
    --query 'sort_by(Datapoints, &Timestamp)[-1]' --output json
}

wait_for_replica_lag() {
  local region="$1" database="$2" data lag timestamp age
  for _ in {1..20}; do
    data="$(latest_replica_lag_json "$region" "$database")"
    lag="$(jq -r '.Maximum // empty' <<<"$data")"
    timestamp="$(jq -r '.Timestamp // empty' <<<"$data")"
    if [ -n "$lag" ] && [ "$lag" != "-1" ] && [ -n "$timestamp" ]; then
      age=$(( $(date -u +%s) - $(to_epoch "$timestamp") ))
      if [ "$age" -le 180 ] && awk -v lag="$lag" -v target="$FAILBACK_LAG_TARGET_SECONDS" 'BEGIN { exit !(lag <= target) }'; then
        printf '%s\t%s\n' "$lag" "$timestamp"
        return 0
      fi
    fi
    sleep 30
  done
  return 1
}

require_dr_writes_frozen() {
  local desired running target_group_arn healthy
  read -r desired running <<<"$(aws ecs describe-services \
    --region "$DR_REGION" \
    --cluster "$DR_CLUSTER" \
    --services "$DR_SERVICE" \
    --query 'services[0].[desiredCount,runningCount]' --output text)"
  target_group_arn="$(aws elbv2 describe-target-groups \
    --region "$DR_REGION" \
    --names "sentinel-aws-dr-dr-tg" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)"
  healthy="$(aws elbv2 describe-target-health \
    --region "$DR_REGION" \
    --target-group-arn "$target_group_arn" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)"
  if [ "$desired" != "0" ] || [ "$running" != "0" ] || [ "$healthy" != "0" ]; then
    echo "ERROR: DR writes are not frozen (desired=$desired running=$running healthy=$healthy)." >&2
    return 1
  fi
}

case "${1:-}" in
snapshot)
  [ "${CONFIRM_FAILBACK_SNAPSHOT:-}" = "YES" ] || {
    echo "Set CONFIRM_FAILBACK_SNAPSHOT=YES to create the temporary safety snapshot." >&2
    exit 1
  }
  require_current_event "traffic_verified_dr"
  read -r dr_status dr_source dr_multi_az <<<"$(aws rds describe-db-instances \
    --region "$DR_REGION" \
    --db-instance-identifier "$DR_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier,MultiAZ]' --output text)"
  if [ "$dr_status" != "available" ] || { [ -n "$dr_source" ] && [ "$dr_source" != "None" ]; } || [ "$dr_multi_az" != "True" ]; then
    echo "ERROR: active DR writer must be available, standalone, and Multi-AZ before its safety snapshot." >&2
    exit 1
  fi
  snapshot_id="${DR_DB_ID}-pre-failback-$(date -u +%Y%m%d%H%M%S)"
  aws rds create-db-snapshot \
    --region "$DR_REGION" \
    --db-instance-identifier "$DR_DB_ID" \
    --db-snapshot-identifier "$snapshot_id" >/dev/null
  aws rds wait db-snapshot-available --region "$DR_REGION" --db-snapshot-identifier "$snapshot_id"
  record_event_at "dr_pre_failback_snapshot" "$snapshot_id"
  cat <<EOF
Snapshot $snapshot_id is available.

Next protected Terraform phase:
  1. Dispatch the failback-prepare plan:
     gh workflow run recovery.yml --ref main -f operation=failback-prepare -f confirm_failback=REBUILD_PROD -f failback_snapshot_id=$snapshot_id
  2. Review the saved plan in the plan job; the dependent apply job consumes that exact plan.
  3. Wait for apply and run: scripts/failback.sh verify-replica

Delete the snapshot after topology reset evidence is complete:
  CONFIRM_DELETE_SNAPSHOT=YES scripts/failback.sh delete-snapshot $snapshot_id
EOF
  ;;

verify-replica)
  read -r status source <<<"$(aws rds describe-db-instances \
    --region "$PROD_REGION" \
    --db-instance-identifier "$PROD_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
  if [ "$status" != "available" ] || [[ "$source" != *"$DR_DB_ID"* ]]; then
    echo "ERROR: prod is not an available replica of $DR_DB_ID." >&2
    exit 1
  fi
  if ! lag_evidence="$(wait_for_replica_lag "$PROD_REGION" "$PROD_DB_ID")"; then
    echo "ERROR: prod replica has no fresh lag evidence within target." >&2
    exit 1
  fi
  IFS=$'\t' read -r lag lag_timestamp <<<"$lag_evidence"
  record_event_at "failback_replica_lag_seconds" "$lag"
  record_event_at "failback_replica_lag_timestamp" "$lag_timestamp"
  log_event "failback_replica_verified"
  cat <<EOF
Prod is an available replica of DR with ReplicaLag ${lag}s.

Next manual phase:
  1. Run: CONFIRM_FAILBACK_FREEZE=YES scripts/failback.sh freeze-writes
  2. Run: CONFIRM_PRIMARY_PROMOTION=YES scripts/failback.sh promote-primary
  3. Run: CONFIRM_FAILBACK_READY=YES scripts/failback.sh ready
EOF
  ;;

freeze-writes)
  [ "${CONFIRM_FAILBACK_FREEZE:-}" = "YES" ] || {
    echo "Set CONFIRM_FAILBACK_FREEZE=YES to stop DR application writes for planned failback." >&2
    exit 1
  }
  require_current_event "traffic_verified_dr"
  require_current_event "failback_replica_verified"

  dr_alb_dns="$(aws elbv2 describe-load-balancers \
    --region "$DR_REGION" \
    --names "sentinel-aws-dr-dr-alb" \
    --query 'LoadBalancers[0].DNSName' --output text)"
  target_group_arn="$(aws elbv2 describe-target-groups \
    --region "$DR_REGION" \
    --names "sentinel-aws-dr-dr-tg" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)"
  require_current_event "dr_link_slug"
  final_link_slug="$(current_event_ts dr_link_slug)"
  if ! require_short_link_direct "$WORKLOAD_HOST" "$dr_alb_dns" "$final_link_slug"; then
    echo "ERROR: active DR does not contain expected link $final_link_slug." >&2
    exit 1
  fi
  aws ecs update-service \
    --region "$DR_REGION" \
    --cluster "$DR_CLUSTER" \
    --service "$DR_SERVICE" \
    --desired-count 0 >/dev/null

  frozen=false
  for _ in {1..90}; do
    read -r desired running <<<"$(aws ecs describe-services \
      --region "$DR_REGION" \
      --cluster "$DR_CLUSTER" \
      --services "$DR_SERVICE" \
      --query 'services[0].[desiredCount,runningCount]' --output text)"
    healthy="$(aws elbv2 describe-target-health \
      --region "$DR_REGION" \
      --target-group-arn "$target_group_arn" \
      --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)"
    if [ "$desired" = "0" ] && [ "$running" = "0" ] && [ "$healthy" = "0" ]; then
      frozen=true
      break
    fi
    sleep 2
  done
  if [ "$frozen" != true ]; then
    echo "ERROR: could not prove DR writes stopped; restoring DR service." >&2
    aws ecs update-service --region "$DR_REGION" --cluster "$DR_CLUSTER" --service "$DR_SERVICE" --desired-count 2 >/dev/null
    exit 1
  fi
  record_event_at "failback_dr_final_link_slug" "$final_link_slug"
  log_event "failback_writes_frozen"
  curl --fail --silent --show-error "https://${MONITOR_HOST}/healthz" >/dev/null
  echo "DR writes are frozen after link $final_link_slug. Canonical workload traffic is unavailable until prod is ready; monitor remains healthy."
  ;;

promote-primary)
  [ "${CONFIRM_PRIMARY_PROMOTION:-}" = "YES" ] || {
    echo "Set CONFIRM_PRIMARY_PROMOTION=YES to promote the synchronized prod replica." >&2
    exit 1
  }
  require_current_event "failback_replica_verified"
  require_current_event "failback_writes_frozen"

  read -r status source <<<"$(aws rds describe-db-instances \
    --region "$PROD_REGION" \
    --db-instance-identifier "$PROD_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
  resume_promoted=false
  promotion_in_progress=false
  if [ -z "$source" ] || [ "$source" = "None" ]; then
    require_current_event "primary_promoted"
    require_current_event "failback_cutover_lag_seconds"
    if [ -n "$(current_event_ts primary_service_stable)" ]; then
      echo "ERROR: current drill already recorded primary_service_stable; refusing an ambiguous retry." >&2
      exit 1
    fi
    resume_promoted=true
  elif [ -n "$(current_event_ts failback_cutover_lag_seconds)" ]; then
    # promote-read-replica was already called earlier in this failback; the
    # instance just has not finished settling (AWS keeps the source ARN set
    # while status is "modifying" mid-promotion). Resume by polling instead
    # of erroring out or calling promote-read-replica a second time.
    echo "Promotion already invoked earlier in this failback (status=$status); resuming poll..."
    promotion_in_progress=true
  elif [ "$status" != "available" ] || [[ "$source" != *"$DR_DB_ID"* ]]; then
    echo "ERROR: prod is not an available replica of $DR_DB_ID." >&2
    exit 1
  fi

  require_dr_writes_frozen

  if [ "$resume_promoted" = false ] && [ "$promotion_in_progress" = false ]; then
    if ! lag_evidence="$(wait_for_replica_lag "$PROD_REGION" "$PROD_DB_ID")"; then
      echo "ERROR: no fresh acceptable prod replica lag evidence after DR writes were frozen." >&2
      exit 1
    fi
    IFS=$'\t' read -r lag lag_timestamp <<<"$lag_evidence"
    record_event_at "failback_cutover_lag_seconds" "$lag"
    record_event_at "failback_cutover_lag_timestamp" "$lag_timestamp"
    require_dr_writes_frozen

    aws rds promote-read-replica \
      --region "$PROD_REGION" \
      --db-instance-identifier "$PROD_DB_ID" >/dev/null
  elif [ "$resume_promoted" = true ]; then
    echo "Resuming current failback after verified prod promotion..."
  fi

  for _ in {1..120}; do
    read -r status source <<<"$(aws rds describe-db-instances \
      --region "$PROD_REGION" \
      --db-instance-identifier "$PROD_DB_ID" \
      --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
    if [ "$status" = "available" ] && { [ -z "$source" ] || [ "$source" = "None" ]; }; then
      break
    fi
    sleep 10
  done
  if [ "$status" != "available" ] || { [ -n "$source" ] && [ "$source" != "None" ]; }; then
    echo "ERROR: prod promotion did not produce an available standalone database." >&2
    exit 1
  fi
  if [ "$resume_promoted" = false ]; then
    log_event "primary_promoted"
  fi

  require_dr_writes_frozen

  read -r status multi_az <<<"$(aws rds describe-db-instances \
    --region "$PROD_REGION" \
    --db-instance-identifier "$PROD_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,MultiAZ]' --output text)"
  if [ "$multi_az" != "True" ]; then
    aws rds modify-db-instance \
      --region "$PROD_REGION" \
      --db-instance-identifier "$PROD_DB_ID" \
      --multi-az \
      --apply-immediately >/dev/null
  fi
  for _ in {1..180}; do
    read -r status multi_az <<<"$(aws rds describe-db-instances \
      --region "$PROD_REGION" \
      --db-instance-identifier "$PROD_DB_ID" \
      --query 'DBInstances[0].[DBInstanceStatus,MultiAZ]' --output text)"
    if [ "$status" = "available" ] && [ "$multi_az" = "True" ]; then
      break
    fi
    sleep 10
  done
  if [ "$status" != "available" ] || [ "$multi_az" != "True" ]; then
    echo "ERROR: prod did not become an available Multi-AZ database." >&2
    exit 1
  fi

  aws ecs update-service \
    --region "$PROD_REGION" \
    --cluster "$PROD_CLUSTER" \
    --service "$PROD_SERVICE" \
    --desired-count 2 >/dev/null
  aws ecs wait services-stable --region "$PROD_REGION" --cluster "$PROD_CLUSTER" --services "$PROD_SERVICE"

  read -r desired running <<<"$(aws ecs describe-services \
    --region "$PROD_REGION" \
    --cluster "$PROD_CLUSTER" \
    --services "$PROD_SERVICE" \
    --query 'services[0].[desiredCount,runningCount]' --output text)"
  if [ "$desired" != "2" ] || [ "$running" != "2" ]; then
    echo "ERROR: prod ECS is not stable at 2/2 tasks." >&2
    exit 1
  fi
  log_event "primary_service_stable"
  echo "Prod is promoted, Multi-AZ, and stable at 2/2 tasks. Run: CONFIRM_FAILBACK_READY=YES scripts/failback.sh ready"
  ;;

ready)
  [ "${CONFIRM_FAILBACK_READY:-}" = "YES" ] || {
    echo "Set CONFIRM_FAILBACK_READY=YES after prod promotion and service startup." >&2
    exit 1
  }
  require_current_event "failback_replica_verified"
  require_current_event "failback_writes_frozen"
  require_current_event "failback_dr_final_link_slug"
  known_link_slug="$(current_event_ts failback_dr_final_link_slug)"

  read -r db_status source multi_az <<<"$(aws rds describe-db-instances \
    --region "$PROD_REGION" \
    --db-instance-identifier "$PROD_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier,MultiAZ]' --output text)"
  if [ "$db_status" != "available" ] || { [ -n "$source" ] && [ "$source" != "None" ]; } || [ "$multi_az" != "True" ]; then
    echo "ERROR: prod must be an available standalone Multi-AZ database before traffic returns." >&2
    exit 1
  fi

  read -r desired running <<<"$(aws ecs describe-services \
    --region "$PROD_REGION" \
    --cluster "$PROD_CLUSTER" \
    --services "$PROD_SERVICE" \
    --query 'services[0].[desiredCount,runningCount]' --output text)"
  if [ "$desired" != "2" ] || [ "$running" != "2" ]; then
    echo "ERROR: prod ECS is not stable at 2/2 tasks." >&2
    exit 1
  fi

  alb_dns="$(aws elbv2 describe-load-balancers \
    --region "$PROD_REGION" \
    --names "sentinel-aws-dr-prod-alb" \
    --query 'LoadBalancers[0].DNSName' --output text)"
  if ! require_short_link_direct "$WORKLOAD_HOST" "$alb_dns" "$known_link_slug"; then
    echo "ERROR: promoted prod does not contain DR-created link $known_link_slug." >&2
    exit 1
  fi
  log_event "failback_ready"
  echo "Prod is Multi-AZ, healthy, and contains DR-created link $known_link_slug. Run: CONFIRM_TRAFFIC_SWITCH=PRIMARY scripts/switch-traffic.sh primary"
  ;;

verify-reset)
  require_current_event "failback_ready"
  require_current_event "traffic_verified_primary"
  read -r dr_status dr_source <<<"$(aws rds describe-db-instances \
    --region "$DR_REGION" \
    --db-instance-identifier "$DR_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
  if [ "$dr_status" != "available" ] || [[ "$dr_source" != *"$PROD_DB_ID"* ]]; then
    echo "ERROR: DR is not an available replica of restored prod." >&2
    exit 1
  fi
  read -r dr_desired dr_running <<<"$(aws ecs describe-services \
    --region "$DR_REGION" \
    --cluster "$DR_CLUSTER" \
    --services "$DR_SERVICE" \
    --query 'services[0].[desiredCount,runningCount]' --output text)"
  if [ "$dr_desired" != "0" ] || [ "$dr_running" != "0" ]; then
    echo "ERROR: DR ECS is not reset to pilot-light count 0." >&2
    exit 1
  fi
  if ! lag_evidence="$(wait_for_replica_lag "$DR_REGION" "$DR_DB_ID")"; then
    echo "ERROR: restored DR replica has no fresh lag evidence within target." >&2
    exit 1
  fi
  IFS=$'\t' read -r lag lag_timestamp <<<"$lag_evidence"
  record_event_at "topology_reset_replica_lag_seconds" "$lag"
  record_event_at "topology_reset_replica_lag_timestamp" "$lag_timestamp"
  log_event "topology_reset_verified"
  echo "Primary-to-DR replica topology and pilot-light ECS count are restored."
  ;;

delete-snapshot)
  snapshot_id="${2:-}"
  [ "${CONFIRM_DELETE_SNAPSHOT:-}" = "YES" ] && [ -n "$snapshot_id" ] || {
    echo "Usage: CONFIRM_DELETE_SNAPSHOT=YES $0 delete-snapshot <snapshot-id>" >&2
    exit 1
  }
  aws rds delete-db-snapshot \
    --region "$DR_REGION" \
    --db-snapshot-identifier "$snapshot_id" >/dev/null
  record_event_at "dr_pre_failback_snapshot_deleted" "$snapshot_id"
  echo "Snapshot deletion requested: $snapshot_id"
  ;;

*)
  echo "Usage: $0 {snapshot|verify-replica|freeze-writes|promote-primary|ready|verify-reset|delete-snapshot <id>}" >&2
  exit 1
  ;;
esac
