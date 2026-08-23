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

readonly PRIMARY_DB_ID="$PRIMARY_RESOURCE_NAME"
readonly SECONDARY_DB_ID="$SECONDARY_RESOURCE_NAME"
readonly PRIMARY_CLUSTER="$PRIMARY_RESOURCE_NAME"
readonly PRIMARY_SERVICE="$PRIMARY_RESOURCE_NAME"
readonly SECONDARY_CLUSTER="$SECONDARY_RESOURCE_NAME"
readonly SECONDARY_SERVICE="$SECONDARY_RESOURCE_NAME"
readonly PRIMARY_ALB_NAME="${PRIMARY_RESOURCE_NAME}-alb"
readonly SECONDARY_ALB_NAME="${SECONDARY_RESOURCE_NAME}-alb"
readonly SECONDARY_TARGET_GROUP_NAME="${SECONDARY_RESOURCE_NAME}-tg"
readonly FAILBACK_LAG_TARGET_SECONDS="${FAILBACK_LAG_TARGET_SECONDS:-300}"

# accepts only recent lag evidence within the configured failback target.
wait_for_replica_lag() {
  local region="$1" database="$2" data lag timestamp age
  for _ in {1..20}; do
    data="$(latest_replica_lag_json "$region" "$database")"
    lag="$(jq -r '.Maximum // empty' <<<"$data")"
    timestamp="$(jq -r '.Timestamp // empty' <<<"$data")"
    # RDS reports ReplicaLag=-1 when replication is not active/determinable; treat as no evidence.
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

# proves no secondary task or healthy target can accept writes during primary promotion.
require_secondary_writes_frozen() {
  local desired running target_group_arn healthy
  read -r desired running <<<"$(aws ecs describe-services \
    --region "$SECONDARY_REGION" \
    --cluster "$SECONDARY_CLUSTER" \
    --services "$SECONDARY_SERVICE" \
    --query 'services[0].[desiredCount,runningCount]' --output text)"
  target_group_arn="$(aws elbv2 describe-target-groups \
    --region "$SECONDARY_REGION" \
    --names "$SECONDARY_TARGET_GROUP_NAME" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)"
  healthy="$(aws elbv2 describe-target-health \
    --region "$SECONDARY_REGION" \
    --target-group-arn "$target_group_arn" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)"
  if [ "$desired" != "0" ] || [ "$running" != "0" ] || [ "$healthy" != "0" ]; then
    echo "error: Secondary writes are not frozen (desired=$desired running=$running healthy=$healthy)" >&2
    return 1
  fi
}

case "${1:-}" in
# step 1: snapshot the secondary writer before destructive primary reconstruction.
snapshot)
  if [ "${CONFIRM_FAILBACK_SNAPSHOT:-}" != "YES" ]; then
    echo "error: set CONFIRM_FAILBACK_SNAPSHOT=YES to create the safety snapshot" >&2
    exit 1
  fi
  require_current_event "traffic_verified_secondary"
  read -r secondary_status secondary_replicates_from secondary_multi_az <<<"$(aws rds describe-db-instances \
    --region "$SECONDARY_REGION" \
    --db-instance-identifier "$SECONDARY_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier,MultiAZ]' --output text)"
  if [ "$secondary_status" != "available" ] || ! has_no_replication_source "$secondary_replicates_from" || [ "$secondary_multi_az" != "True" ]; then
    echo "error: active secondary writer must be available, standalone, and Multi-AZ before snapshot" >&2
    exit 1
  fi
  snapshot_id="${SECONDARY_DB_ID}-pre-failback-$(date -u +%Y%m%d%H%M%S)"
  aws rds create-db-snapshot \
    --region "$SECONDARY_REGION" \
    --db-instance-identifier "$SECONDARY_DB_ID" \
    --db-snapshot-identifier "$snapshot_id" >/dev/null
  aws rds wait db-snapshot-available --region "$SECONDARY_REGION" --db-snapshot-identifier "$snapshot_id"
  record_event_at "secondary_pre_failback_snapshot" "$snapshot_id"
  cat <<EOF
Snapshot $snapshot_id is available.

Next protected Terraform phase:
  1. Dispatch the failback-prepare plan:
     gh workflow run recovery.yml --ref main -f operation=failback-prepare -f confirm=true -f failback_snapshot_id=$snapshot_id
  2. Review the saved plan in the plan job; the dependent apply job consumes that exact plan.
  3. Wait for apply and run: scripts/drills/failback.sh verify-replica

Delete the snapshot after topology reset evidence is complete:
  CONFIRM_DELETE_SNAPSHOT=YES scripts/drills/failback.sh delete-snapshot $snapshot_id
EOF
  ;;

# step 2: verify the rebuilt primary replica is current before cutover.
verify-replica)
  read -r status primary_replicates_from <<<"$(aws rds describe-db-instances \
    --region "$PRIMARY_REGION" \
    --db-instance-identifier "$PRIMARY_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
  if [ "$status" != "available" ] || [[ "$primary_replicates_from" != *"$SECONDARY_DB_ID"* ]]; then
    echo "error: primary is not an available replica of $SECONDARY_DB_ID" >&2
    exit 1
  fi
  if ! lag_evidence="$(wait_for_replica_lag "$PRIMARY_REGION" "$PRIMARY_DB_ID")"; then
    echo "error: primary replica has no fresh lag evidence within target" >&2
    exit 1
  fi
  IFS=$'\t' read -r lag lag_timestamp <<<"$lag_evidence"
  record_event_at "failback_replica_lag_seconds" "$lag"
  record_event_at "failback_replica_lag_timestamp" "$lag_timestamp"
  log_event "failback_replica_verified"
  cat <<EOF
Primary is an available replica of secondary with ReplicaLag ${lag}s.

Next manual phase:
  1. Run: CONFIRM_FAILBACK_FREEZE=YES scripts/drills/failback.sh freeze-writes
  2. Run: CONFIRM_PRIMARY_PROMOTION=YES scripts/drills/failback.sh promote-primary
  3. Run: CONFIRM_FAILBACK_READY=YES scripts/drills/failback.sh ready
EOF
  ;;

# step 3: freeze secondary writes before promoting primary.
freeze-writes)
  if [ "${CONFIRM_FAILBACK_FREEZE:-}" != "YES" ]; then
    echo "error: set CONFIRM_FAILBACK_FREEZE=YES to stop secondary writes for planned failback" >&2
    exit 1
  fi
  require_current_event "traffic_verified_secondary"
  require_current_event "failback_replica_verified"

  # captures the final known secondary write before removing all application writers.
  secondary_alb_dns="$(aws elbv2 describe-load-balancers \
    --region "$SECONDARY_REGION" \
    --names "$SECONDARY_ALB_NAME" \
    --query 'LoadBalancers[0].DNSName' --output text)"
  target_group_arn="$(aws elbv2 describe-target-groups \
    --region "$SECONDARY_REGION" \
    --names "$SECONDARY_TARGET_GROUP_NAME" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)"
  require_current_event "secondary_link_slug"
  final_link_slug="$(current_event_ts secondary_link_slug)"
  if ! require_short_link_direct "$WORKLOAD_HOST" "$secondary_alb_dns" "$final_link_slug"; then
    echo "error: active secondary does not contain expected link $final_link_slug" >&2
    exit 1
  fi
  aws ecs update-service \
    --region "$SECONDARY_REGION" \
    --cluster "$SECONDARY_CLUSTER" \
    --service "$SECONDARY_SERVICE" \
    --desired-count 0 >/dev/null

  # requires zero tasks and healthy targets before treating secondary writes as frozen.
  frozen=false
  for _ in {1..90}; do
    read -r desired running <<<"$(aws ecs describe-services \
      --region "$SECONDARY_REGION" \
      --cluster "$SECONDARY_CLUSTER" \
      --services "$SECONDARY_SERVICE" \
      --query 'services[0].[desiredCount,runningCount]' --output text)"
    healthy="$(aws elbv2 describe-target-health \
      --region "$SECONDARY_REGION" \
      --target-group-arn "$target_group_arn" \
      --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)"
    if [ "$desired" = "0" ] && [ "$running" = "0" ] && [ "$healthy" = "0" ]; then
      frozen=true
      break
    fi
    sleep 2
  done
  if [ "$frozen" != true ]; then
    echo "error: could not prove secondary writes stopped; restoring secondary service" >&2
    aws ecs update-service --region "$SECONDARY_REGION" --cluster "$SECONDARY_CLUSTER" --service "$SECONDARY_SERVICE" --desired-count 2 >/dev/null
    exit 1
  fi
  record_event_at "failback_secondary_final_link_slug" "$final_link_slug"
  log_event "failback_writes_frozen"
  curl --fail --silent --show-error "https://${SENTRY_HOST}/healthz" >/dev/null
  echo "Secondary writes are frozen after link $final_link_slug. Canonical workload traffic is unavailable until primary is ready; sentry remains healthy."
  ;;

# step 4: promote primary, restore Multi-AZ durability, and start primary compute.
promote-primary)
  if [ "${CONFIRM_PRIMARY_PROMOTION:-}" != "YES" ]; then
    echo "error: set CONFIRM_PRIMARY_PROMOTION=YES to promote the synchronized primary replica" >&2
    exit 1
  fi
  require_current_event "failback_replica_verified"
  require_current_event "failback_writes_frozen"

  # classifies fresh, in-progress, and resumed failback promotion states.
  read -r status primary_replicates_from <<<"$(aws rds describe-db-instances \
    --region "$PRIMARY_REGION" \
    --db-instance-identifier "$PRIMARY_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
  promotion_state="fresh"
  if has_no_replication_source "$primary_replicates_from"; then
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
  elif [ "$status" != "available" ] || [[ "$primary_replicates_from" != *"$SECONDARY_DB_ID"* ]]; then
    echo "error: primary is not an available replica of $SECONDARY_DB_ID" >&2
    exit 1
  fi

  require_secondary_writes_frozen

  # measures final lag between two write-freeze checks so evidence reflects cutover state.
  case "$promotion_state" in
  fresh)
    if ! lag_evidence="$(wait_for_replica_lag "$PRIMARY_REGION" "$PRIMARY_DB_ID")"; then
      echo "error: no fresh acceptable primary replica lag evidence after secondary writes were frozen" >&2
      exit 1
    fi
    IFS=$'\t' read -r lag lag_timestamp <<<"$lag_evidence"
    record_event_at "failback_cutover_lag_seconds" "$lag"
    record_event_at "failback_cutover_lag_timestamp" "$lag_timestamp"
    require_secondary_writes_frozen

    aws rds promote-read-replica \
      --region "$PRIMARY_REGION" \
      --db-instance-identifier "$PRIMARY_DB_ID" >/dev/null
    log_event "primary_promotion_invoked"
    ;;
  promoted)
    echo "Resuming current failback after verified primary promotion..."
    ;;
  in_progress)
    echo "Primary promotion is still in progress; resuming status polling..."
    ;;
  *)
    echo "error: unknown promotion state: $promotion_state" >&2
    exit 1
    ;;
  esac

  # waits up to 20 minutes for primary to become an available standalone writer.
  for _ in {1..120}; do
    read -r status primary_replicates_from <<<"$(aws rds describe-db-instances \
      --region "$PRIMARY_REGION" \
      --db-instance-identifier "$PRIMARY_DB_ID" \
      --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
    if [ "$status" = "available" ] && has_no_replication_source "$primary_replicates_from"; then
      break
    fi
    sleep 10
  done
  if [ "$status" != "available" ] || ! has_no_replication_source "$primary_replicates_from"; then
    echo "error: primary promotion did not produce an available standalone database" >&2
    exit 1
  fi
  if [ -z "$(current_event_ts primary_promoted)" ]; then
    log_event "primary_promoted"
  fi

  require_secondary_writes_frozen

  # restores Multi-AZ durability because replica promotion yields a Single-AZ writer.
  read -r status multi_az <<<"$(aws rds describe-db-instances \
    --region "$PRIMARY_REGION" \
    --db-instance-identifier "$PRIMARY_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,MultiAZ]' --output text)"
  if [ "$multi_az" != "True" ]; then
    aws rds modify-db-instance \
      --region "$PRIMARY_REGION" \
      --db-instance-identifier "$PRIMARY_DB_ID" \
      --multi-az \
      --apply-immediately >/dev/null
  fi

  # waits up to 30 minutes for Multi-AZ conversion to settle.
  for _ in {1..180}; do
    read -r status multi_az <<<"$(aws rds describe-db-instances \
      --region "$PRIMARY_REGION" \
      --db-instance-identifier "$PRIMARY_DB_ID" \
      --query 'DBInstances[0].[DBInstanceStatus,MultiAZ]' --output text)"
    if [ "$status" = "available" ] && [ "$multi_az" = "True" ]; then
      break
    fi
    sleep 10
  done
  if [ "$status" != "available" ] || [ "$multi_az" != "True" ]; then
    echo "error: primary did not become an available Multi-AZ database" >&2
    exit 1
  fi

  # a promoted replica keeps the password it inherited from secondary; reconcile it against
  # the canonical SSM secret before starting compute, so tasks never launch with a stale one.
  db_password="$(aws ssm get-parameter --region "$PRIMARY_REGION" \
    --name "/$PROJECT_NAME/primary/database/password" --with-decryption \
    --query 'Parameter.Value' --output text)"
  trap 'unset db_password' EXIT
  aws rds modify-db-instance --region "$PRIMARY_REGION" \
    --db-instance-identifier "$PRIMARY_DB_ID" \
    --master-user-password "$db_password" --apply-immediately >/dev/null
  aws rds wait db-instance-available --region "$PRIMARY_REGION" --db-instance-identifier "$PRIMARY_DB_ID"

  # starts primary compute only after database promotion, Multi-AZ conversion, and credential reconciliation finish.
  aws ecs update-service \
    --region "$PRIMARY_REGION" \
    --cluster "$PRIMARY_CLUSTER" \
    --service "$PRIMARY_SERVICE" \
    --desired-count 2 >/dev/null
  aws ecs wait services-stable --region "$PRIMARY_REGION" --cluster "$PRIMARY_CLUSTER" --services "$PRIMARY_SERVICE"

  # verifies waiter success against explicit desired and running counts.
  read -r desired running <<<"$(aws ecs describe-services \
    --region "$PRIMARY_REGION" \
    --cluster "$PRIMARY_CLUSTER" \
    --services "$PRIMARY_SERVICE" \
    --query 'services[0].[desiredCount,runningCount]' --output text)"
  if [ "$desired" != "2" ] || [ "$running" != "2" ]; then
    echo "error: primary ECS is not stable at 2/2 tasks" >&2
    exit 1
  fi

  # requires two-AZ task placement before failback can proceed to returning traffic.
  if ! require_two_az_tasks "$PRIMARY_REGION" "$PRIMARY_CLUSTER" "$PRIMARY_SERVICE"; then
    echo "error: Primary tasks are not running across two Availability Zones; do not return traffic" >&2
    exit 1
  fi
  log_event "primary_service_stable"
  echo "Primary is promoted, Multi-AZ, and stable at 2/2 tasks. Run: CONFIRM_FAILBACK_READY=YES scripts/drills/failback.sh ready"
  ;;

# step 5: verify primary topology, capacity, and final secondary write before returning traffic.
ready)
  if [ "${CONFIRM_FAILBACK_READY:-}" != "YES" ]; then
    echo "error: set CONFIRM_FAILBACK_READY=YES after primary promotion and service startup" >&2
    exit 1
  fi
  require_current_event "failback_replica_verified"
  require_current_event "failback_writes_frozen"
  require_current_event "failback_secondary_final_link_slug"
  known_link_slug="$(current_event_ts failback_secondary_final_link_slug)"

  # rechecks database topology because traffic switching makes primary authoritative again.
  read -r db_status primary_replicates_from multi_az <<<"$(aws rds describe-db-instances \
    --region "$PRIMARY_REGION" \
    --db-instance-identifier "$PRIMARY_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier,MultiAZ]' --output text)"
  if [ "$db_status" != "available" ] || ! has_no_replication_source "$primary_replicates_from" || [ "$multi_az" != "True" ]; then
    echo "error: primary must be an available standalone Multi-AZ database before traffic returns" >&2
    exit 1
  fi

  read -r desired running <<<"$(aws ecs describe-services \
    --region "$PRIMARY_REGION" \
    --cluster "$PRIMARY_CLUSTER" \
    --services "$PRIMARY_SERVICE" \
    --query 'services[0].[desiredCount,runningCount]' --output text)"
  if [ "$desired" != "2" ] || [ "$running" != "2" ]; then
    echo "error: primary ECS is not stable at 2/2 tasks" >&2
    exit 1
  fi

  # rechecks two-AZ task placement as the final gate before traffic actually returns.
  if ! require_two_az_tasks "$PRIMARY_REGION" "$PRIMARY_CLUSTER" "$PRIMARY_SERVICE"; then
    echo "error: Primary tasks are not running across two Availability Zones; do not return traffic" >&2
    exit 1
  fi

  # bypasses Route 53 to prove primary contains the final secondary write before cutover.
  alb_dns="$(aws elbv2 describe-load-balancers \
    --region "$PRIMARY_REGION" \
    --names "$PRIMARY_ALB_NAME" \
    --query 'LoadBalancers[0].DNSName' --output text)"
  if ! require_short_link_direct "$WORKLOAD_HOST" "$alb_dns" "$known_link_slug"; then
    echo "error: promoted primary does not contain secondary-created link $known_link_slug" >&2
    exit 1
  fi
  log_event "failback_ready"
  echo "Primary is Multi-AZ, healthy, and contains secondary-created link $known_link_slug. Run: CONFIRM_TRAFFIC_SWITCH=primary scripts/drills/switch-traffic.sh primary"
  ;;

# step 6: verify protected reset restored resting pilot-light topology.
verify-reset)
  require_current_event "failback_ready"
  require_current_event "traffic_verified_primary"

  # proves secondary returned to replica-at-rest state after the protected reset workflow.
  read -r secondary_status secondary_replicates_from <<<"$(aws rds describe-db-instances \
    --region "$SECONDARY_REGION" \
    --db-instance-identifier "$SECONDARY_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
  if [ "$secondary_status" != "available" ] || [[ "$secondary_replicates_from" != *"$PRIMARY_DB_ID"* ]]; then
    echo "error: Secondary is not an available replica of restored primary" >&2
    exit 1
  fi
  read -r secondary_desired secondary_running <<<"$(aws ecs describe-services \
    --region "$SECONDARY_REGION" \
    --cluster "$SECONDARY_CLUSTER" \
    --services "$SECONDARY_SERVICE" \
    --query 'services[0].[desiredCount,runningCount]' --output text)"
  if [ "$secondary_desired" != "0" ] || [ "$secondary_running" != "0" ]; then
    echo "error: Secondary ECS is not reset to pilot-light count 0" >&2
    exit 1
  fi

  # requires fresh replication evidence after rebuilding the secondary replica.
  if ! lag_evidence="$(wait_for_replica_lag "$SECONDARY_REGION" "$SECONDARY_DB_ID")"; then
    echo "error: restored secondary replica has no fresh lag evidence within target" >&2
    exit 1
  fi
  IFS=$'\t' read -r lag lag_timestamp <<<"$lag_evidence"
  record_event_at "topology_reset_replica_lag_seconds" "$lag"
  record_event_at "topology_reset_replica_lag_timestamp" "$lag_timestamp"
  log_event "topology_reset_verified"
  echo "Primary-to-secondary replica topology and pilot-light ECS count are restored."
  ;;

# cleanup: remove rollback snapshot only after topology reset is verified.
delete-snapshot)
  snapshot_id="${2:-}"
  if [ "${CONFIRM_DELETE_SNAPSHOT:-}" != "YES" ] || [ -z "$snapshot_id" ]; then
    echo "usage: CONFIRM_DELETE_SNAPSHOT=YES $0 delete-snapshot <snapshot-id>" >&2
    exit 1
  fi
  require_current_event "topology_reset_verified"
  require_current_event "secondary_pre_failback_snapshot"
  recorded_snapshot_id="$(current_event_ts secondary_pre_failback_snapshot)"

  # prevents deleting an unrelated snapshot supplied by operator input.
  if [ "$snapshot_id" != "$recorded_snapshot_id" ]; then
    echo "error: snapshot $snapshot_id is not current rollback snapshot $recorded_snapshot_id" >&2
    exit 1
  fi
  aws rds delete-db-snapshot \
    --region "$SECONDARY_REGION" \
    --db-snapshot-identifier "$snapshot_id" >/dev/null
  record_event_at "secondary_pre_failback_snapshot_deleted" "$snapshot_id"
  echo "Snapshot deletion requested: $snapshot_id"
  ;;

*)
  echo "usage: $0 {snapshot|verify-replica|freeze-writes|promote-primary|ready|verify-reset|delete-snapshot <id>}" >&2
  exit 1
  ;;
esac
