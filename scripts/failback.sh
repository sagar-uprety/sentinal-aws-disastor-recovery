#!/usr/bin/env bash
# Runs guarded failback operations while Terraform mutations stay in protected GitHub Actions jobs.
# Assumes the active AWS CLI credentials have permission for the requested recovery operation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/drill-lib.sh"

PROD_REGION="eu-central-1"
DR_REGION="eu-west-1"
PROD_DB_ID="sentinel-aws-dr-prod"
DR_DB_ID="sentinel-aws-dr-dr"
PROD_CLUSTER="sentinel-aws-dr-prod"
PROD_SERVICE="sentinel-aws-dr-prod"
DR_CLUSTER="sentinel-aws-dr-dr"
DR_SERVICE="sentinel-aws-dr-dr"
STATUS_HOST="status.sentinel.sagaruprety.com.np"
RPO_TARGET_URL="${RPO_TARGET_URL:-https://${STATUS_HOST}}"
FAILBACK_LAG_TARGET_SECONDS="${FAILBACK_LAG_TARGET_SECONDS:-30}"

latest_replica_lag() {
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
    --query 'sort_by(Datapoints, &Timestamp)[-1].Maximum' --output text
}

case "${1:-}" in
snapshot)
  [ "${CONFIRM_FAILBACK_SNAPSHOT:-}" = "YES" ] || {
    echo "Set CONFIRM_FAILBACK_SNAPSHOT=YES to create the temporary safety snapshot." >&2
    exit 1
  }
  snapshot_id="${PROD_DB_ID}-pre-failback-$(date -u +%Y%m%d%H%M%S)"
  aws rds create-db-snapshot \
    --region "$PROD_REGION" \
    --db-instance-identifier "$PROD_DB_ID" \
    --db-snapshot-identifier "$snapshot_id" >/dev/null
  aws rds wait db-snapshot-available --region "$PROD_REGION" --db-snapshot-identifier "$snapshot_id"
  record_event_at "prod_pre_failback_snapshot" "$snapshot_id"
  cat <<EOF
Snapshot $snapshot_id is available.

Next protected Terraform phase:
  1. Dispatch the protected failback-prepare workflow:
     gh workflow run recovery.yml --ref main -f operation=failback-prepare -f confirm_failback=REBUILD_PROD -f failback_snapshot_id=$snapshot_id
  2. Follow the plan and apply job logs; the apply job consumes the saved plan.
  3. Wait for the workflow and run: scripts/failback.sh verify-replica

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
  lag="$(latest_replica_lag "$PROD_REGION" "$PROD_DB_ID")"
  if [ -z "$lag" ] || [ "$lag" = "None" ] || [ "$lag" = "-1" ]; then
    echo "ERROR: prod replica lag is unavailable." >&2
    exit 1
  fi
  if ! awk -v lag="$lag" -v target="$FAILBACK_LAG_TARGET_SECONDS" 'BEGIN { exit !(lag <= target) }'; then
    echo "ERROR: prod replica lag ${lag}s exceeds ${FAILBACK_LAG_TARGET_SECONDS}s." >&2
    exit 1
  fi
  record_event_at "failback_replica_lag_seconds" "$lag"
  log_event "failback_replica_verified"
  cat <<EOF
Prod is an available replica of DR with ReplicaLag ${lag}s.

Next manual phase:
  1. Stop or freeze application writes briefly if this were a real incident.
  2. Run: CONFIRM_PRIMARY_PROMOTION=YES scripts/failback.sh promote-primary
  3. Run: CONFIRM_FAILBACK_READY=YES scripts/failback.sh ready
EOF
  ;;

promote-primary)
  [ "${CONFIRM_PRIMARY_PROMOTION:-}" = "YES" ] || {
    echo "Set CONFIRM_PRIMARY_PROMOTION=YES to promote the synchronized prod replica." >&2
    exit 1
  }
  require_current_event "failback_replica_verified"

  read -r status source <<<"$(aws rds describe-db-instances \
    --region "$PROD_REGION" \
    --db-instance-identifier "$PROD_DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
  if [ "$status" != "available" ] || [[ "$source" != *"$DR_DB_ID"* ]]; then
    echo "ERROR: prod is not an available replica of $DR_DB_ID." >&2
    exit 1
  fi

  aws rds promote-read-replica \
    --region "$PROD_REGION" \
    --db-instance-identifier "$PROD_DB_ID" >/dev/null
  aws rds wait db-instance-available --region "$PROD_REGION" --db-instance-identifier "$PROD_DB_ID"
  log_event "primary_promoted"

  aws rds modify-db-instance \
    --region "$PROD_REGION" \
    --db-instance-identifier "$PROD_DB_ID" \
    --multi-az \
    --apply-immediately >/dev/null
  aws rds wait db-instance-available --region "$PROD_REGION" --db-instance-identifier "$PROD_DB_ID"

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
  require_current_event "dr_known_row"
  known_row="$(current_event_ts dr_known_row)"

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
  encoded_target="$(jq -rn --arg value "$RPO_TARGET_URL" '$value | @uri')"
  history="$(curl -fsS --connect-to "${STATUS_HOST}:443:${alb_dns}:443" "https://${STATUS_HOST}/history?target=${encoded_target}&limit=500")"
  if ! jq -e --arg known "$known_row" 'any(.[]; .checked_at == $known)' >/dev/null <<<"$history"; then
    echo "ERROR: promoted prod does not contain the known row written in DR at $known_row." >&2
    exit 1
  fi
  log_event "failback_ready"
  echo "Prod is Multi-AZ, healthy, and contains the known DR-written row. Run: CONFIRM_TRAFFIC_SWITCH=PRIMARY scripts/switch-traffic.sh primary"
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
  lag="$(latest_replica_lag "$DR_REGION" "$DR_DB_ID")"
  if [ -z "$lag" ] || [ "$lag" = "None" ] || [ "$lag" = "-1" ]; then
    echo "ERROR: restored DR replica lag is unavailable." >&2
    exit 1
  fi
  record_event_at "topology_reset_replica_lag_seconds" "$lag"
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
    --region "$PROD_REGION" \
    --db-snapshot-identifier "$snapshot_id" >/dev/null
  record_event_at "prod_pre_failback_snapshot_deleted" "$snapshot_id"
  echo "Snapshot deletion requested: $snapshot_id"
  ;;

*)
  echo "Usage: $0 {snapshot|verify-replica|promote-primary|ready|verify-reset|delete-snapshot <id>}" >&2
  exit 1
  ;;
esac
