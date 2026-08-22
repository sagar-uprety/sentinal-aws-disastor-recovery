#!/usr/bin/env bash
# runs guarded failback steps while Terraform mutations remain in protected workflows.
# assumes active AWS credentials permit requested recovery operations.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=../config.sh
source "$SCRIPT_DIR/../config.sh"
# shellcheck source=drill-lib.sh
source "$SCRIPT_DIR/drill-lib.sh"

readonly PROD_DB_ID="$PROD_RESOURCE_NAME"
readonly DR_DB_ID="$DR_RESOURCE_NAME"
readonly PROD_CLUSTER="$PROD_RESOURCE_NAME"
readonly PROD_SERVICE="$PROD_RESOURCE_NAME"
readonly DR_CLUSTER="$DR_RESOURCE_NAME"
readonly DR_SERVICE="$DR_RESOURCE_NAME"
readonly PROD_ALB_NAME="${PROD_RESOURCE_NAME}-alb"
readonly DR_ALB_NAME="${DR_RESOURCE_NAME}-alb"
readonly DR_TARGET_GROUP_NAME="${DR_RESOURCE_NAME}-tg"
readonly FAILBACK_LAG_TARGET_SECONDS="${FAILBACK_LAG_TARGET_SECONDS:-300}"

# fetches the newest maximum ReplicaLag datapoint from a five-minute window.
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

# accepts only recent lag evidence within the configured failback target.
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

# proves no DR task or healthy target can accept writes during prod promotion.
require_dr_writes_frozen() {
  local desired running target_group_arn healthy
  read -r desired running <<<"$(aws ecs describe-services \
    --region "$DR_REGION" \
    --cluster "$DR_CLUSTER" \
    --services "$DR_SERVICE" \
    --query 'services[0].[desiredCount,runningCount]' --output text)"
  target_group_arn="$(aws elbv2 describe-target-groups \
    --region "$DR_REGION" \
    --names "$DR_TARGET_GROUP_NAME" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)"
  healthy="$(aws elbv2 describe-target-health \
    --region "$DR_REGION" \
    --target-group-arn "$target_group_arn" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)"
  if [ "$desired" != "0" ] || [ "$running" != "0" ] || [ "$healthy" != "0" ]; then
    echo "error: DR writes are not frozen (desired=$desired running=$running healthy=$healthy)" >&2
    return 1
  fi
}

case "${1:-}" in
# step 1: snapshot the DR writer before destructive prod reconstruction.
snapshot)
  [ "${CONFIRM_FAILBACK_SNAPSHOT:-}" = "YES" ] || {
    echo "error: set CONFIRM_FAILBACK_SNAPSHOT=YES to create the safety snapshot" >&2
    exit 1
  }
  require_current_event "traffic_verified_dr"
  read -r dr_status dr_source dr_multi_az <<<"$(aws rds describe-db-instances \
    --region "$DR_REGION" \
    --db-instance-identifier "$DR_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier,MultiAZ]' --output text)"
  if [ "$dr_status" != "available" ] || ! replica_source_is_empty "$dr_source" || [ "$dr_multi_az" != "True" ]; then
    echo "error: active DR writer must be available, standalone, and Multi-AZ before snapshot" >&2
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
  3. Wait for apply and run: scripts/drills/failback.sh verify-replica

Delete the snapshot after topology reset evidence is complete:
  CONFIRM_DELETE_SNAPSHOT=YES scripts/drills/failback.sh delete-snapshot $snapshot_id
EOF
  ;;

# step 2: verify the rebuilt prod replica is current before cutover.
verify-replica)
  read -r status source <<<"$(aws rds describe-db-instances \
    --region "$PRIMARY_REGION" \
    --db-instance-identifier "$PROD_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
  if [ "$status" != "available" ] || [[ "$source" != *"$DR_DB_ID"* ]]; then
    echo "error: prod is not an available replica of $DR_DB_ID" >&2
    exit 1
  fi
  if ! lag_evidence="$(wait_for_replica_lag "$PRIMARY_REGION" "$PROD_DB_ID")"; then
    echo "error: prod replica has no fresh lag evidence within target" >&2
    exit 1
  fi
  IFS=$'\t' read -r lag lag_timestamp <<<"$lag_evidence"
  record_event_at "failback_replica_lag_seconds" "$lag"
  record_event_at "failback_replica_lag_timestamp" "$lag_timestamp"
  log_event "failback_replica_verified"
  cat <<EOF
Prod is an available replica of DR with ReplicaLag ${lag}s.

Next manual phase:
  1. Run: CONFIRM_FAILBACK_FREEZE=YES scripts/drills/failback.sh freeze-writes
  2. Run: CONFIRM_PRIMARY_PROMOTION=YES scripts/drills/failback.sh promote-primary
  3. Run: CONFIRM_FAILBACK_READY=YES scripts/drills/failback.sh ready
EOF
  ;;

# step 3: freeze DR writes before promoting prod.
freeze-writes)
  [ "${CONFIRM_FAILBACK_FREEZE:-}" = "YES" ] || {
    echo "error: set CONFIRM_FAILBACK_FREEZE=YES to stop DR writes for planned failback" >&2
    exit 1
  }
  require_current_event "traffic_verified_dr"
  require_current_event "failback_replica_verified"

  # captures the final known DR write before removing all application writers.
  dr_alb_dns="$(aws elbv2 describe-load-balancers \
    --region "$DR_REGION" \
    --names "$DR_ALB_NAME" \
    --query 'LoadBalancers[0].DNSName' --output text)"
  target_group_arn="$(aws elbv2 describe-target-groups \
    --region "$DR_REGION" \
    --names "$DR_TARGET_GROUP_NAME" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)"
  require_current_event "dr_link_slug"
  final_link_slug="$(current_event_ts dr_link_slug)"
  if ! require_short_link_direct "$WORKLOAD_HOST" "$dr_alb_dns" "$final_link_slug"; then
    echo "error: active DR does not contain expected link $final_link_slug" >&2
    exit 1
  fi
  aws ecs update-service \
    --region "$DR_REGION" \
    --cluster "$DR_CLUSTER" \
    --service "$DR_SERVICE" \
    --desired-count 0 >/dev/null

  # requires zero tasks and healthy targets before treating DR writes as frozen.
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
    echo "error: could not prove DR writes stopped; restoring DR service" >&2
    aws ecs update-service --region "$DR_REGION" --cluster "$DR_CLUSTER" --service "$DR_SERVICE" --desired-count 2 >/dev/null
    exit 1
  fi
  record_event_at "failback_dr_final_link_slug" "$final_link_slug"
  log_event "failback_writes_frozen"
  curl --fail --silent --show-error "https://${MONITOR_HOST}/healthz" >/dev/null
  echo "DR writes are frozen after link $final_link_slug. Canonical workload traffic is unavailable until prod is ready; monitor remains healthy."
  ;;

# step 4: promote prod, restore Multi-AZ durability, and start primary compute.
promote-primary)
  [ "${CONFIRM_PRIMARY_PROMOTION:-}" = "YES" ] || {
    echo "error: set CONFIRM_PRIMARY_PROMOTION=YES to promote the synchronized prod replica" >&2
    exit 1
  }
  require_current_event "failback_replica_verified"
  require_current_event "failback_writes_frozen"

  # classifies fresh, in-progress, and resumed failback promotion states.
  read -r status source <<<"$(aws rds describe-db-instances \
    --region "$PRIMARY_REGION" \
    --db-instance-identifier "$PROD_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
  promotion_state="fresh"
  if replica_source_is_empty "$source"; then
    require_current_event "primary_promotion_invoked"
    require_current_event "failback_cutover_lag_seconds"
    if [ -n "$(current_event_ts primary_service_stable)" ]; then
      echo "error: current drill already recorded primary_service_stable; refusing ambiguous retry" >&2
      exit 1
    fi
    promotion_state="promoted"
  elif [ -n "$(current_event_ts primary_promotion_invoked)" ]; then
    # resumes polling because AWS retains the source ARN while promotion is modifying.
    promotion_state="in_progress"
  elif [ "$status" != "available" ] || [[ "$source" != *"$DR_DB_ID"* ]]; then
    echo "error: prod is not an available replica of $DR_DB_ID" >&2
    exit 1
  fi

  require_dr_writes_frozen

  # measures final lag between two write-freeze checks so evidence reflects cutover state.
  case "$promotion_state" in
  fresh)
    if ! lag_evidence="$(wait_for_replica_lag "$PRIMARY_REGION" "$PROD_DB_ID")"; then
      echo "error: no fresh acceptable prod replica lag evidence after DR writes were frozen" >&2
      exit 1
    fi
    IFS=$'\t' read -r lag lag_timestamp <<<"$lag_evidence"
    record_event_at "failback_cutover_lag_seconds" "$lag"
    record_event_at "failback_cutover_lag_timestamp" "$lag_timestamp"
    require_dr_writes_frozen

    aws rds promote-read-replica \
      --region "$PRIMARY_REGION" \
      --db-instance-identifier "$PROD_DB_ID" >/dev/null
    log_event "primary_promotion_invoked"
    ;;
  promoted)
    echo "Resuming current failback after verified prod promotion..."
    ;;
  in_progress)
    echo "Prod promotion is still in progress; resuming status polling..."
    ;;
  *)
    echo "error: unknown promotion state: $promotion_state" >&2
    exit 1
    ;;
  esac

  # waits up to 20 minutes for prod to become an available standalone writer.
  for _ in {1..120}; do
    read -r status source <<<"$(aws rds describe-db-instances \
      --region "$PRIMARY_REGION" \
      --db-instance-identifier "$PROD_DB_ID" \
      --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
    if [ "$status" = "available" ] && replica_source_is_empty "$source"; then
      break
    fi
    sleep 10
  done
  if [ "$status" != "available" ] || ! replica_source_is_empty "$source"; then
    echo "error: prod promotion did not produce an available standalone database" >&2
    exit 1
  fi
  if [ -z "$(current_event_ts primary_promoted)" ]; then
    log_event "primary_promoted"
  fi

  require_dr_writes_frozen

  # restores Multi-AZ durability because replica promotion yields a Single-AZ writer.
  read -r status multi_az <<<"$(aws rds describe-db-instances \
    --region "$PRIMARY_REGION" \
    --db-instance-identifier "$PROD_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,MultiAZ]' --output text)"
  if [ "$multi_az" != "True" ]; then
    aws rds modify-db-instance \
      --region "$PRIMARY_REGION" \
      --db-instance-identifier "$PROD_DB_ID" \
      --multi-az \
      --apply-immediately >/dev/null
  fi

  # waits up to 30 minutes for Multi-AZ conversion to settle.
  for _ in {1..180}; do
    read -r status multi_az <<<"$(aws rds describe-db-instances \
      --region "$PRIMARY_REGION" \
      --db-instance-identifier "$PROD_DB_ID" \
      --query 'DBInstances[0].[DBInstanceStatus,MultiAZ]' --output text)"
    if [ "$status" = "available" ] && [ "$multi_az" = "True" ]; then
      break
    fi
    sleep 10
  done
  if [ "$status" != "available" ] || [ "$multi_az" != "True" ]; then
    echo "error: prod did not become an available Multi-AZ database" >&2
    exit 1
  fi

  # starts primary compute only after database promotion and Multi-AZ conversion finish.
  aws ecs update-service \
    --region "$PRIMARY_REGION" \
    --cluster "$PROD_CLUSTER" \
    --service "$PROD_SERVICE" \
    --desired-count 2 >/dev/null
  aws ecs wait services-stable --region "$PRIMARY_REGION" --cluster "$PROD_CLUSTER" --services "$PROD_SERVICE"

  # verifies waiter success against explicit desired and running counts.
  read -r desired running <<<"$(aws ecs describe-services \
    --region "$PRIMARY_REGION" \
    --cluster "$PROD_CLUSTER" \
    --services "$PROD_SERVICE" \
    --query 'services[0].[desiredCount,runningCount]' --output text)"
  if [ "$desired" != "2" ] || [ "$running" != "2" ]; then
    echo "error: prod ECS is not stable at 2/2 tasks" >&2
    exit 1
  fi
  log_event "primary_service_stable"
  echo "Prod is promoted, Multi-AZ, and stable at 2/2 tasks. Run: CONFIRM_FAILBACK_READY=YES scripts/drills/failback.sh ready"
  ;;

# step 5: verify prod topology, capacity, and final DR write before returning traffic.
ready)
  [ "${CONFIRM_FAILBACK_READY:-}" = "YES" ] || {
    echo "error: set CONFIRM_FAILBACK_READY=YES after prod promotion and service startup" >&2
    exit 1
  }
  require_current_event "failback_replica_verified"
  require_current_event "failback_writes_frozen"
  require_current_event "failback_dr_final_link_slug"
  known_link_slug="$(current_event_ts failback_dr_final_link_slug)"

  # rechecks database topology because traffic switching makes prod authoritative again.
  read -r db_status source multi_az <<<"$(aws rds describe-db-instances \
    --region "$PRIMARY_REGION" \
    --db-instance-identifier "$PROD_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier,MultiAZ]' --output text)"
  if [ "$db_status" != "available" ] || ! replica_source_is_empty "$source" || [ "$multi_az" != "True" ]; then
    echo "error: prod must be an available standalone Multi-AZ database before traffic returns" >&2
    exit 1
  fi

  read -r desired running <<<"$(aws ecs describe-services \
    --region "$PRIMARY_REGION" \
    --cluster "$PROD_CLUSTER" \
    --services "$PROD_SERVICE" \
    --query 'services[0].[desiredCount,runningCount]' --output text)"
  if [ "$desired" != "2" ] || [ "$running" != "2" ]; then
    echo "error: prod ECS is not stable at 2/2 tasks" >&2
    exit 1
  fi

  # bypasses Route 53 to prove prod contains the final DR write before cutover.
  alb_dns="$(aws elbv2 describe-load-balancers \
    --region "$PRIMARY_REGION" \
    --names "$PROD_ALB_NAME" \
    --query 'LoadBalancers[0].DNSName' --output text)"
  if ! require_short_link_direct "$WORKLOAD_HOST" "$alb_dns" "$known_link_slug"; then
    echo "error: promoted prod does not contain DR-created link $known_link_slug" >&2
    exit 1
  fi
  log_event "failback_ready"
  echo "Prod is Multi-AZ, healthy, and contains DR-created link $known_link_slug. Run: CONFIRM_TRAFFIC_SWITCH=PRIMARY scripts/drills/switch-traffic.sh primary"
  ;;

# step 6: verify protected reset restored resting pilot-light topology.
verify-reset)
  require_current_event "failback_ready"
  require_current_event "traffic_verified_primary"

  # proves DR returned to replica-at-rest state after the protected reset workflow.
  read -r dr_status dr_source <<<"$(aws rds describe-db-instances \
    --region "$DR_REGION" \
    --db-instance-identifier "$DR_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
  if [ "$dr_status" != "available" ] || [[ "$dr_source" != *"$PROD_DB_ID"* ]]; then
    echo "error: DR is not an available replica of restored prod" >&2
    exit 1
  fi
  read -r dr_desired dr_running <<<"$(aws ecs describe-services \
    --region "$DR_REGION" \
    --cluster "$DR_CLUSTER" \
    --services "$DR_SERVICE" \
    --query 'services[0].[desiredCount,runningCount]' --output text)"
  if [ "$dr_desired" != "0" ] || [ "$dr_running" != "0" ]; then
    echo "error: DR ECS is not reset to pilot-light count 0" >&2
    exit 1
  fi

  # requires fresh replication evidence after rebuilding the DR replica.
  if ! lag_evidence="$(wait_for_replica_lag "$DR_REGION" "$DR_DB_ID")"; then
    echo "error: restored DR replica has no fresh lag evidence within target" >&2
    exit 1
  fi
  IFS=$'\t' read -r lag lag_timestamp <<<"$lag_evidence"
  record_event_at "topology_reset_replica_lag_seconds" "$lag"
  record_event_at "topology_reset_replica_lag_timestamp" "$lag_timestamp"
  log_event "topology_reset_verified"
  echo "Primary-to-DR replica topology and pilot-light ECS count are restored."
  ;;

# cleanup: remove rollback snapshot only after topology reset is verified.
delete-snapshot)
  snapshot_id="${2:-}"
  [ "${CONFIRM_DELETE_SNAPSHOT:-}" = "YES" ] && [ -n "$snapshot_id" ] || {
    echo "usage: CONFIRM_DELETE_SNAPSHOT=YES $0 delete-snapshot <snapshot-id>" >&2
    exit 1
  }
  require_current_event "topology_reset_verified"
  require_current_event "dr_pre_failback_snapshot"
  recorded_snapshot_id="$(current_event_ts dr_pre_failback_snapshot)"

  # prevents deleting an unrelated snapshot supplied by operator input.
  if [ "$snapshot_id" != "$recorded_snapshot_id" ]; then
    echo "error: snapshot $snapshot_id is not current rollback snapshot $recorded_snapshot_id" >&2
    exit 1
  fi
  aws rds delete-db-snapshot \
    --region "$DR_REGION" \
    --db-snapshot-identifier "$snapshot_id" >/dev/null
  record_event_at "dr_pre_failback_snapshot_deleted" "$snapshot_id"
  echo "Snapshot deletion requested: $snapshot_id"
  ;;

*)
  echo "usage: $0 {snapshot|verify-replica|freeze-writes|promote-primary|ready|verify-reset|delete-snapshot <id>}" >&2
  exit 1
  ;;
esac
