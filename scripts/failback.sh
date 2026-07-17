#!/usr/bin/env bash
# Failback is NOT a single reversible command: once DR has accepted writes,
# the old prod database has diverged and cannot simply "resume" as primary.
# This script automates the safe, mechanical pieces (snapshot, post-rebuild
# verification) and prints the manual Terraform steps for the parts that
# require editing which environment replicates from which -- doing that
# silently from a script would be a bigger blast radius than typing it.
#
# Usage:
#   ./failback.sh snapshot   Snapshot the stale prod DB before touching it.
#   ./failback.sh verify     After the Terraform rebuild below, verify the
#                            new prod replica is lagging < 30s and has a
#                            known post-promotion row.
set -euo pipefail

PROD_REGION="eu-central-1"
DR_REGION="eu-west-1"
PROD_DB_ID="sentinel-aws-dr-prod"
DR_DB_ID="sentinel-aws-dr-dr"
DRILL_LOG="${DRILL_LOG:-./drill-events.log}"

log_event() {
  echo "${1}	$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$DRILL_LOG"
}

cmd="${1:-}"

case "$cmd" in
snapshot)
  snapshot_id="${PROD_DB_ID}-pre-failback-$(date -u +%Y%m%d%H%M%S)"
  echo "Snapshotting stale prod DB as ${snapshot_id} before any failback changes..."
  aws rds create-db-snapshot \
    --region "$PROD_REGION" \
    --db-instance-identifier "$PROD_DB_ID" \
    --db-snapshot-identifier "$snapshot_id" >/dev/null
  aws rds wait db-snapshot-available --region "$PROD_REGION" --db-snapshot-identifier "$snapshot_id"
  log_event "prod_pre_failback_snapshot:${snapshot_id}"
  echo "Snapshot complete. Now do the manual rebuild steps below, then run: $0 verify"
  cat <<'EOF'

Manual rebuild (Terraform-driven, not scripted):
  1. In terraform/environments/prod/main.tf, point module.rds at the DR
     instance as its replication source (replicate_source_db_arn = DR's
     ARN, same pattern the dr environment currently uses against prod).
  2. terraform destroy -target=module.rds in prod (removes the stale,
     diverged instance -- the snapshot above is the safety net).
  3. terraform apply in prod to create the new prod-region replica of the
     now-primary DR database.
  4. Do NOT revert step 1 in DR yet -- DR remains primary until this new
     replica is available and verified.

Destructive alternative (documented, not automated): restore prod directly
from the pre-failback snapshot instead of reverse-replicating. Faster, but
loses every write made in DR after promotion -- state the data-loss window
and RTO explicitly if you use this path instead.
EOF
  ;;

verify)
  echo "Checking replica lag on rebuilt prod (${PROD_DB_ID})..."
  lag="$(aws cloudwatch get-metric-statistics \
    --region "$PROD_REGION" \
    --namespace AWS/RDS \
    --metric-name ReplicaLag \
    --dimensions Name=DBInstanceIdentifier,Value="$PROD_DB_ID" \
    --start-time "$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 60 --statistics Average \
    --query 'sort_by(Datapoints, &Timestamp)[-1].Average' --output text)"
  echo "Replica lag: ${lag}s"
  if [ "$lag" = "None" ]; then
    echo "No lag datapoint yet -- replica may still be initializing. Retry shortly." >&2
    exit 1
  fi
  log_event "failback_replica_lag:${lag}s"
  echo "Confirm a known row written in DR is present in the rebuilt prod replica before switching traffic back."
  ;;

*)
  echo "Usage: $0 {snapshot|verify}" >&2
  exit 1
  ;;
esac
