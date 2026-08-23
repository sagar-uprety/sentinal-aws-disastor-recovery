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
# writes are frozen by cutover, so replication must fully drain before promoting.
readonly FAILBACK_CUTOVER_LAG_SECONDS="${FAILBACK_CUTOVER_LAG_SECONDS:-0}"

# polls up to ten minutes for lag evidence within the caller's target; per-attempt failures are
# expected while replication drains, so the helper's reasons are silenced until the whole wait fails.
wait_for_replica_lag() {
  local region="$1" database="$2" target="${3:-$FAILBACK_LAG_TARGET_SECONDS}" evidence lag timestamp
  for _ in {1..20}; do
    if evidence="$(fresh_replica_lag "$region" "$database" 2>/dev/null)"; then
      IFS=$'\t' read -r lag timestamp <<<"$evidence"
      if lag_within_target "$lag" "$target"; then
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
  read -r desired running <<<"$(ecs_service_counts "$SECONDARY_REGION" "$SECONDARY_CLUSTER" "$SECONDARY_SERVICE")"
  target_group_arn="$(target_group_arn_for "$SECONDARY_REGION" "$SECONDARY_TARGET_GROUP_NAME")"
  healthy="$(healthy_target_count "$SECONDARY_REGION" "$target_group_arn")"
  if [ "$desired" != "0" ] || [ "$running" != "0" ] || [ "$healthy" != "0" ]; then
    echo "error: Secondary writes are not frozen (desired=$desired running=$running healthy=$healthy)" >&2
    return 1
  fi
}

# step 1: snapshot the secondary writer before destructive primary reconstruction.
step_snapshot() {
  local secondary_status secondary_replicates_from secondary_multi_az snapshot_id
  # ==== PRECHECKS ====
  if [ "${CONFIRM_FAILBACK_SNAPSHOT:-}" != "YES" ]; then
    echo "error: set CONFIRM_FAILBACK_SNAPSHOT=YES to create the safety snapshot" >&2
    exit 1
  fi
  require_current_event "traffic_verified_secondary"
  read -r secondary_status secondary_replicates_from secondary_multi_az <<<"$(db_topology "$SECONDARY_REGION" "$SECONDARY_DB_ID")"
  if [ "$secondary_status" != "available" ] || ! has_no_replication_source "$secondary_replicates_from" || [ "$secondary_multi_az" != "True" ]; then
    echo "error: active secondary writer must be available, standalone, and Multi-AZ before snapshot" >&2
    exit 1
  fi

  # ==== MAIN TASK: capture the rollback snapshot ====
  snapshot_id="${SECONDARY_DB_ID}-pre-failback-$(date -u +%Y%m%d%H%M%S)"
  aws rds create-db-snapshot \
    --region "$SECONDARY_REGION" \
    --db-instance-identifier "$SECONDARY_DB_ID" \
    --db-snapshot-identifier "$snapshot_id" >/dev/null
  aws rds wait db-snapshot-available --region "$SECONDARY_REGION" --db-snapshot-identifier "$snapshot_id"
  record_event_at "secondary_pre_failback_snapshot" "$snapshot_id"
  echo "Snapshot $snapshot_id is available. Dispatch failback-prepare with failback_snapshot_id=$snapshot_id (see docs/runbook-failover.md)."
}

# step 2: verify the rebuilt primary replica is current before cutover.
step_verify_replica() {
  local status primary_replicates_from lag_evidence lag lag_timestamp
  read -r status primary_replicates_from _ <<<"$(db_topology "$PRIMARY_REGION" "$PRIMARY_DB_ID")"
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
  echo "Primary is an available replica of secondary with ReplicaLag ${lag}s."
}

# step 3: freeze secondary writes before promoting primary.
step_freeze_writes() {
  local secondary_alb_dns target_group_arn final_link_slug frozen desired running healthy pre_freeze_desired
  # ==== PRECHECKS ====
  if [ "${CONFIRM_FAILBACK_FREEZE:-}" != "YES" ]; then
    echo "error: set CONFIRM_FAILBACK_FREEZE=YES to stop secondary writes for planned failback" >&2
    exit 1
  fi
  require_current_event "traffic_verified_secondary"
  require_current_event "failback_replica_verified"

  # captures the final known secondary write before removing all application writers.
  secondary_alb_dns="$(alb_dns_name "$SECONDARY_REGION" "$SECONDARY_ALB_NAME")"
  target_group_arn="$(target_group_arn_for "$SECONDARY_REGION" "$SECONDARY_TARGET_GROUP_NAME")"
  require_current_event "secondary_link_slug"
  final_link_slug="$(current_drill_event_ts secondary_link_slug)"
  if ! require_short_link_direct "$WORKLOAD_HOST" "$secondary_alb_dns" "$final_link_slug"; then
    echo "error: active secondary does not contain expected link $final_link_slug" >&2
    exit 1
  fi

  # ==== MAIN TASK: scale secondary compute to zero ====
  read -r pre_freeze_desired _ <<<"$(ecs_service_counts "$SECONDARY_REGION" "$SECONDARY_CLUSTER" "$SECONDARY_SERVICE")"
  aws ecs update-service \
    --region "$SECONDARY_REGION" \
    --cluster "$SECONDARY_CLUSTER" \
    --service "$SECONDARY_SERVICE" \
    --desired-count 0 >/dev/null

  # ==== POSTCHECKS ====
  # zero tasks is not enough on its own; a draining target can still accept a write.
  frozen=false
  for _ in {1..90}; do
    read -r desired running <<<"$(ecs_service_counts "$SECONDARY_REGION" "$SECONDARY_CLUSTER" "$SECONDARY_SERVICE")"
    healthy="$(healthy_target_count "$SECONDARY_REGION" "$target_group_arn")"
    if [ "$desired" = "0" ] && [ "$running" = "0" ] && [ "$healthy" = "0" ]; then
      frozen=true
      break
    fi
    sleep 2
  done
  if [ "$frozen" != true ]; then
    echo "error: could not prove secondary writes stopped; restoring secondary service" >&2
    aws ecs update-service --region "$SECONDARY_REGION" --cluster "$SECONDARY_CLUSTER" --service "$SECONDARY_SERVICE" --desired-count "$pre_freeze_desired" >/dev/null
    exit 1
  fi
  record_event_at "failback_secondary_final_link_slug" "$final_link_slug"
  log_event "failback_writes_frozen"
  curl --fail --silent --show-error "https://${SENTRY_HOST}/healthz" >/dev/null
  echo "Secondary writes are frozen after link $final_link_slug. Canonical workload traffic is unavailable until primary is ready; sentry remains healthy."
}

# step 4: promote primary, restore Multi-AZ durability, and start primary compute.
step_promote_primary() {
  local status primary_replicates_from promotion_state lag_evidence lag lag_timestamp
  local multi_az db_password desired running
  # ==== PRECHECKS ====
  if [ "${CONFIRM_PRIMARY_PROMOTION:-}" != "YES" ]; then
    echo "error: set CONFIRM_PRIMARY_PROMOTION=YES to promote the synchronized primary replica" >&2
    exit 1
  fi
  require_current_event "failback_replica_verified"
  require_current_event "failback_writes_frozen"

  # classifies fresh, in-progress, and resumed failback promotion states.
  read -r status primary_replicates_from _ <<<"$(db_topology "$PRIMARY_REGION" "$PRIMARY_DB_ID")"
  promotion_state="fresh"
  if has_no_replication_source "$primary_replicates_from"; then
    require_current_event "primary_promotion_invoked"
    require_current_event "failback_cutover_lag_seconds"
    if [ -n "$(current_drill_event_ts primary_service_stable)" ]; then
      echo "error: current drill already recorded primary_service_stable; refusing ambiguous retry" >&2
      exit 1
    fi
    promotion_state="promoted"
  else
    # exact identifier or ARN suffix, never a substring: a name that merely contains this one
    # is a different instance. Checked before in_progress so a resume cannot skip it.
    if [[ "$primary_replicates_from" != "$SECONDARY_DB_ID" && "$primary_replicates_from" != *":db:${SECONDARY_DB_ID}" ]]; then
      echo "error: primary replicates from $primary_replicates_from, expected $SECONDARY_DB_ID" >&2
      exit 1
    fi
    # resumes polling because AWS retains the source ARN while promotion is modifying.
    if [ -n "$(current_drill_event_ts primary_promotion_invoked)" ]; then
      promotion_state="in_progress"
    elif [ "$status" != "available" ]; then
      echo "error: primary is not an available replica of $SECONDARY_DB_ID" >&2
      exit 1
    fi
  fi

  require_secondary_writes_frozen

  # ==== MAIN TASK: promote primary, restore Multi-AZ, reconcile password, start compute ====
  # measures final lag between two write-freeze checks so evidence reflects cutover state.
  case "$promotion_state" in
  fresh)
    if ! lag_evidence="$(wait_for_replica_lag "$PRIMARY_REGION" "$PRIMARY_DB_ID" "$FAILBACK_CUTOVER_LAG_SECONDS")"; then
      echo "error: primary replica did not drain to ${FAILBACK_CUTOVER_LAG_SECONDS}s lag after secondary writes were frozen" >&2
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

  # promotion reboots the instance, so completion takes minutes, not seconds.
  for _ in {1..120}; do
    read -r status primary_replicates_from _ <<<"$(db_topology "$PRIMARY_REGION" "$PRIMARY_DB_ID")"
    if [ "$status" = "available" ] && has_no_replication_source "$primary_replicates_from"; then
      break
    fi
    sleep 10
  done
  if [ "$status" != "available" ] || ! has_no_replication_source "$primary_replicates_from"; then
    echo "error: primary promotion did not produce an available standalone database" >&2
    exit 1
  fi
  if [ -z "$(current_drill_event_ts primary_promoted)" ]; then
    log_event "primary_promoted"
  fi

  require_secondary_writes_frozen

  # restores Multi-AZ durability because replica promotion yields a Single-AZ writer.
  read -r status _ multi_az <<<"$(db_topology "$PRIMARY_REGION" "$PRIMARY_DB_ID")"
  if [ "$multi_az" != "True" ]; then
    aws rds modify-db-instance \
      --region "$PRIMARY_REGION" \
      --db-instance-identifier "$PRIMARY_DB_ID" \
      --multi-az \
      --apply-immediately >/dev/null
  fi

  # conversion builds a whole standby and syncs it, the slowest step in the failback.
  for _ in {1..180}; do
    read -r status _ multi_az <<<"$(db_topology "$PRIMARY_REGION" "$PRIMARY_DB_ID")"
    if [ "$status" = "available" ] && [ "$multi_az" = "True" ]; then
      break
    fi
    sleep 10
  done
  if [ "$status" != "available" ] || [ "$multi_az" != "True" ]; then
    echo "error: primary did not become an available Multi-AZ database" >&2
    exit 1
  fi

  # a promoted replica keeps secondary's inherited password, which primary's tasks do not
  # have; without this they would all fail to connect and look like a startup failure.
  db_password="$(aws ssm get-parameter --region "$PRIMARY_REGION" \
    --name "/$PROJECT_NAME/primary/database/password" --with-decryption \
    --query 'Parameter.Value' --output text)"
  trap 'unset db_password' EXIT
  aws rds modify-db-instance --region "$PRIMARY_REGION" \
    --db-instance-identifier "$PRIMARY_DB_ID" \
    --master-user-password "$db_password" --apply-immediately >/dev/null
  aws rds wait db-instance-available --region "$PRIMARY_REGION" --db-instance-identifier "$PRIMARY_DB_ID"

  # compute starts last: tasks would crash-loop against a stale password or absent writer.
  aws ecs update-service \
    --region "$PRIMARY_REGION" \
    --cluster "$PRIMARY_CLUSTER" \
    --service "$PRIMARY_SERVICE" \
    --desired-count "$WORKLOAD_DESIRED_COUNT" >/dev/null
  aws ecs wait services-stable --region "$PRIMARY_REGION" --cluster "$PRIMARY_CLUSTER" --services "$PRIMARY_SERVICE"

  # ==== POSTCHECKS ====
  # the waiter can return before both counts match, so they are checked directly.
  read -r desired running <<<"$(ecs_service_counts "$PRIMARY_REGION" "$PRIMARY_CLUSTER" "$PRIMARY_SERVICE")"
  if [ "$desired" != "$WORKLOAD_DESIRED_COUNT" ] || [ "$running" != "$WORKLOAD_DESIRED_COUNT" ]; then
    echo "error: primary ECS is not stable at ${WORKLOAD_DESIRED_COUNT}/${WORKLOAD_DESIRED_COUNT} tasks" >&2
    exit 1
  fi

  # requires full AZ spread before failback can proceed to returning traffic.
  if ! require_task_az_spread "$PRIMARY_REGION" "$PRIMARY_CLUSTER" "$PRIMARY_SERVICE"; then
    echo "error: Primary tasks are not spread across ${WORKLOAD_AZ_COUNT} Availability Zones; do not return traffic" >&2
    exit 1
  fi
  log_event "primary_service_stable"
  echo "Primary is promoted, Multi-AZ, and stable at ${WORKLOAD_DESIRED_COUNT}/${WORKLOAD_DESIRED_COUNT} tasks."
}

# step 5: final go/no-go, re-proving everything since steps can run hours apart.
step_ready() {
  local known_link_slug db_status primary_replicates_from multi_az desired running alb_dns
  # ==== PRECHECKS ====
  if [ "${CONFIRM_FAILBACK_READY:-}" != "YES" ]; then
    echo "error: set CONFIRM_FAILBACK_READY=YES after primary promotion and service startup" >&2
    exit 1
  fi
  require_current_event "failback_replica_verified"
  require_current_event "failback_writes_frozen"
  require_current_event "failback_secondary_final_link_slug"
  known_link_slug="$(current_drill_event_ts failback_secondary_final_link_slug)"

  # rechecks database topology because traffic switching makes primary authoritative again.
  read -r db_status primary_replicates_from multi_az <<<"$(db_topology "$PRIMARY_REGION" "$PRIMARY_DB_ID")"
  if [ "$db_status" != "available" ] || ! has_no_replication_source "$primary_replicates_from" || [ "$multi_az" != "True" ]; then
    echo "error: primary must be an available standalone Multi-AZ database before traffic returns" >&2
    exit 1
  fi

  read -r desired running <<<"$(ecs_service_counts "$PRIMARY_REGION" "$PRIMARY_CLUSTER" "$PRIMARY_SERVICE")"
  if [ "$desired" != "$WORKLOAD_DESIRED_COUNT" ] || [ "$running" != "$WORKLOAD_DESIRED_COUNT" ]; then
    echo "error: primary ECS is not stable at ${WORKLOAD_DESIRED_COUNT}/${WORKLOAD_DESIRED_COUNT} tasks" >&2
    exit 1
  fi

  # rechecks AZ spread as the final gate before traffic actually returns.
  if ! require_task_az_spread "$PRIMARY_REGION" "$PRIMARY_CLUSTER" "$PRIMARY_SERVICE"; then
    echo "error: Primary tasks are not spread across ${WORKLOAD_AZ_COUNT} Availability Zones; do not return traffic" >&2
    exit 1
  fi

  # bypasses Route 53 to prove primary contains the final secondary write before cutover.
  alb_dns="$(alb_dns_name "$PRIMARY_REGION" "$PRIMARY_ALB_NAME")"
  if ! require_short_link_direct "$WORKLOAD_HOST" "$alb_dns" "$known_link_slug"; then
    echo "error: promoted primary does not contain secondary-created link $known_link_slug" >&2
    exit 1
  fi
  log_event "failback_ready"
  echo "Primary is Multi-AZ, healthy, and contains secondary-created link $known_link_slug."
}

# step 6: verify protected reset restored resting pilot-light topology.
step_verify_reset() {
  local secondary_status secondary_replicates_from secondary_desired secondary_running
  local lag_evidence lag lag_timestamp
  require_current_event "failback_ready"
  require_current_event "traffic_verified_primary"

  # proves secondary returned to replica-at-rest state after the protected reset workflow.
  read -r secondary_status secondary_replicates_from _ <<<"$(db_topology "$SECONDARY_REGION" "$SECONDARY_DB_ID")"
  if [ "$secondary_status" != "available" ] || [[ "$secondary_replicates_from" != *"$PRIMARY_DB_ID"* ]]; then
    echo "error: Secondary is not an available replica of restored primary" >&2
    exit 1
  fi
  read -r secondary_desired secondary_running <<<"$(ecs_service_counts "$SECONDARY_REGION" "$SECONDARY_CLUSTER" "$SECONDARY_SERVICE")"
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
}

# cleanup: remove rollback snapshot only after topology reset is verified.
step_delete_snapshot() {
  local snapshot_id="$1" recorded_snapshot_id
  require_current_event "topology_reset_verified"
  require_current_event "secondary_pre_failback_snapshot"
  recorded_snapshot_id="$(current_drill_event_ts secondary_pre_failback_snapshot)"

  # defaults to the drill's own recorded snapshot when the chained run supplies no id.
  if [ -z "$snapshot_id" ]; then
    snapshot_id="$recorded_snapshot_id"
  fi

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
}

case "${1:-}" in
snapshot)
  step_snapshot
  ;;

verify-replica)
  step_verify_replica
  ;;

freeze-writes)
  step_freeze_writes
  ;;

promote-primary)
  step_promote_primary
  ;;

ready)
  step_ready
  ;;

verify-reset)
  step_verify_reset
  ;;

delete-snapshot)
  if [ "${CONFIRM_DELETE_SNAPSHOT:-}" != "YES" ] || [ -z "${2:-}" ]; then
    echo "usage: CONFIRM_DELETE_SNAPSHOT=YES $0 delete-snapshot <snapshot-id>" >&2
    exit 1
  fi
  step_delete_snapshot "$2"
  ;;

# chains steps 2-5 between the two protected Terraform workflows; each step keeps its own
# guards, so a failure stops the chain and the matching single step resumes from there.
cutover)
  if [ "${CONFIRM_FAILBACK_CUTOVER:-}" != "YES" ]; then
    echo "error: set CONFIRM_FAILBACK_CUTOVER=YES to run verify-replica through ready in one pass" >&2
    exit 1
  fi
  export CONFIRM_FAILBACK_FREEZE=YES CONFIRM_PRIMARY_PROMOTION=YES CONFIRM_FAILBACK_READY=YES
  step_verify_replica
  step_freeze_writes
  step_promote_primary
  step_ready
  echo "Cutover complete. Primary is ready; traffic has NOT been returned yet."
  ;;

# chains the post-reset verification and snapshot cleanup after the failback-reset workflow.
finalize)
  if [ "${CONFIRM_FAILBACK_FINALIZE:-}" != "YES" ]; then
    echo "error: set CONFIRM_FAILBACK_FINALIZE=YES to verify the reset and delete the rollback snapshot" >&2
    exit 1
  fi
  step_verify_reset
  step_delete_snapshot ""
  ;;

*)
  echo "usage: $0 {snapshot|cutover|finalize}" >&2
  echo "       single steps for resuming a failed chain: verify-replica|freeze-writes|promote-primary|ready|verify-reset|delete-snapshot <id>" >&2
  exit 1
  ;;
esac
