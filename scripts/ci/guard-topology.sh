#!/usr/bin/env bash
# centralizes topology assertions used on both sides of protected workflow gates.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=../config.sh
source "$SCRIPT_DIR/../config.sh"

readonly PRIMARY_DATABASE="$PRIMARY_RESOURCE_NAME"
readonly SECONDARY_DATABASE="$SECONDARY_RESOURCE_NAME"
readonly PRIMARY_CLUSTER="$PRIMARY_RESOURCE_NAME"
readonly SECONDARY_CLUSTER="$SECONDARY_RESOURCE_NAME"
# 6h: an older snapshot predates this failover and is not a valid rollback point.
readonly SNAPSHOT_MAX_AGE=21600
# bounds post-repair recovery polling in seconds.
readonly WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"

# gives every workflow guard a consistent fatal error format.
fail() {
  echo "error: guard-topology: $1" >&2
  exit 1
}

# filters client-side so an absent database returns MISSING instead of erroring out.
replica_source_of() {
  aws rds describe-db-instances \
    --region "$1" \
    --output json |
    jq -r --arg identifier "$2" '
      (.DBInstances | map(select(.DBInstanceIdentifier == $identifier)) | .[0]) as $database
      | if $database == null then "MISSING"
        else ($database.ReadReplicaSourceDBInstanceIdentifier // "None")
        end
    '
}

# keeps sentry reads consistent across guards that inspect reported topology.
topology_json() {
  curl --fail --show-error --silent "$SENTRY_URL/topology"
}

# ensures public DNS exposes every Route 53 nameserver required by ACM and failover records.
guard_route53_delegation() {
  local zone_id nameserver
  zone_id="$(aws route53 list-hosted-zones-by-name \
    --dns-name "${BASE_DOMAIN}." \
    --query "HostedZones[?Name=='${BASE_DOMAIN}.'].Id | [0]" --output text)"
  for nameserver in $(aws route53 get-hosted-zone --id "$zone_id" \
    --query 'DelegationSet.NameServers' --output text); do
    if ! dig +short NS "$BASE_DOMAIN" | grep -Fxq "${nameserver%.}."; then
      fail "missing public delegation to $nameserver; apply bootstrap and publish its nameservers at the registrar or parent zone first"
    fi
  done
}

# the only valid steady state: primary standalone, secondary replicating from it.
guard_no_failback() {
  local primary_replicates_from secondary_replicates_from
  primary_replicates_from="$(replica_source_of "$PRIMARY_REGION" "$PRIMARY_DATABASE")"
  secondary_replicates_from="$(replica_source_of "$SECONDARY_REGION" "$SECONDARY_DATABASE")"
  if [ "$primary_replicates_from" = "MISSING" ] && [ "$secondary_replicates_from" = "MISSING" ]; then
    return
  fi
  if [ "$primary_replicates_from" = "MISSING" ]; then
    fail "primary database is missing while secondary still exists"
  fi
  if ! has_no_replication_source "$primary_replicates_from"; then
    fail "primary is a secondary replica; database topology is in failback, use recovery.yml"
  fi
  if [ "$secondary_replicates_from" = "MISSING" ]; then
    return
  fi
  if has_no_replication_source "$secondary_replicates_from"; then
    fail "Secondary is a standalone writer; database topology is in failback, use recovery.yml"
  fi
}

# permits missing secondary during destroy while still blocking reverse replication.
guard_no_reverse_replication() {
  local primary_replicates_from
  primary_replicates_from="$(replica_source_of "$PRIMARY_REGION" "$PRIMARY_DATABASE")"
  if [ "$primary_replicates_from" = "MISSING" ]; then
    return
  fi
  if ! has_no_replication_source "$primary_replicates_from"; then
    fail "primary is still a secondary replica; complete recovery.yml failback-reset before destroy"
  fi
}

# requires primary to be available and detached from every replication source.
guard_primary_standalone_writer() {
  local status replicates_from
  read -r status replicates_from <<<"$(aws rds describe-db-instances \
    --region "$PRIMARY_REGION" \
    --db-instance-identifier "$PRIMARY_DATABASE" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
  if [ "$status" != "available" ]; then
    fail "primary database is $status, expected available"
  fi
  if ! has_no_replication_source "$replicates_from"; then
    fail "primary database still replicates from $replicates_from, expected a standalone writer"
  fi
}

# adds the production durability requirement used after failback promotion; one query covers
# both this and the standalone-writer check to avoid a second describe-db-instances call.
guard_primary_multi_az_writer() {
  local status replicates_from multi_az
  read -r status replicates_from multi_az <<<"$(aws rds describe-db-instances \
    --region "$PRIMARY_REGION" \
    --db-instance-identifier "$PRIMARY_DATABASE" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier,MultiAZ]' --output text)"
  if [ "$status" != "available" ]; then
    fail "primary database is $status, expected available"
  fi
  if ! has_no_replication_source "$replicates_from"; then
    fail "primary database still replicates from $replicates_from, expected a standalone writer"
  fi
  if [ "$multi_az" != "True" ]; then
    fail "primary database is not Multi-AZ"
  fi
}

# verifies resting pilot-light topology before dependent operations continue.
guard_secondary_pilot_light() {
  local desired replicates_from
  desired="$(aws ecs describe-services \
    --region "$SECONDARY_REGION" --cluster "$SECONDARY_CLUSTER" --services "$SECONDARY_CLUSTER" \
    --query 'services[0].desiredCount' --output text)"
  replicates_from="$(replica_source_of "$SECONDARY_REGION" "$SECONDARY_DATABASE")"
  if [ "$desired" != "0" ]; then
    fail "Secondary desired count is $desired, expected 0 at rest"
  fi
  if has_no_replication_source "$replicates_from"; then
    fail "Secondary database is a standalone writer, expected a replica of primary"
  fi
  if [[ "$replicates_from" != *"$PRIMARY_DATABASE"* ]]; then
    fail "Secondary database replicates from $replicates_from, expected $PRIMARY_DATABASE"
  fi
}

# mirror of guard_secondary_pilot_light for the reversed failback topology, asserting the
# state failback-prepare must leave behind: primary a replica of secondary, serving nothing.
guard_primary_reverse_replica() {
  local desired replicates_from
  desired="$(aws ecs describe-services \
    --region "$PRIMARY_REGION" --cluster "$PRIMARY_CLUSTER" --services "$PRIMARY_CLUSTER" \
    --query 'services[0].desiredCount' --output text)"
  replicates_from="$(replica_source_of "$PRIMARY_REGION" "$PRIMARY_DATABASE")"
  if [ "$desired" != "0" ]; then
    fail "Primary desired count is $desired, expected 0 before serving traffic"
  fi
  if has_no_replication_source "$replicates_from"; then
    fail "Primary database is a standalone writer, expected a replica of secondary"
  fi
  if [[ "$replicates_from" != *"$SECONDARY_DATABASE"* ]]; then
    fail "Primary database replicates from $replicates_from, expected $SECONDARY_DATABASE"
  fi
}

# prevents secondary reset until primary is serving from an available Multi-AZ writer.
guard_primary_serving_traffic() {
  if ! curl --fail --show-error --silent "$WORKLOAD_URL/healthz" >/dev/null; then
    fail "primary workload is not serving /healthz"
  fi
  if ! jq -e --arg region "$PRIMARY_REGION" \
    'any(.regions[]; .region == $region and .database.available and .database.multi_az)' \
    >/dev/null <<<"$(topology_json)"; then
    fail "sentry topology does not report primary as available and Multi-AZ"
  fi
  guard_primary_standalone_writer
}

# requires a fresh encrypted secondary snapshot before destructive primary reconstruction.
guard_safety_snapshot() {
  local snapshot_id="${1:?safety-snapshot requires a snapshot id}"
  local status snapshot_source_db encrypted created age
  local secondary_status secondary_replicates_from secondary_multi_az

  if [[ "$snapshot_id" != "${SECONDARY_DATABASE}-pre-failback-"* ]]; then
    fail "snapshot $snapshot_id is not a ${SECONDARY_DATABASE}-pre-failback-* snapshot"
  fi

  read -r status snapshot_source_db encrypted created <<<"$(aws rds describe-db-snapshots \
    --region "$SECONDARY_REGION" \
    --db-snapshot-identifier "$snapshot_id" \
    --query 'DBSnapshots[0].[Status,DBInstanceIdentifier,Encrypted,SnapshotCreateTime]' --output text)"
  age=$(( $(date -u +%s) - $(to_epoch "$created") ))
  if [ "$status" != "available" ]; then
    fail "snapshot is $status, expected available"
  fi
  if [ "$snapshot_source_db" != "$SECONDARY_DATABASE" ]; then
    fail "snapshot is of $snapshot_source_db, expected $SECONDARY_DATABASE"
  fi
  if [ "$encrypted" != "True" ]; then
    fail "snapshot is not encrypted"
  fi
  if [ "$age" -gt "$SNAPSHOT_MAX_AGE" ]; then
    fail "snapshot is ${age}s old, exceeds ${SNAPSHOT_MAX_AGE}s"
  fi

  read -r secondary_status secondary_replicates_from secondary_multi_az <<<"$(aws rds describe-db-instances \
    --region "$SECONDARY_REGION" \
    --db-instance-identifier "$SECONDARY_DATABASE" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier,MultiAZ]' --output text)"
  if [ "$secondary_status" != "available" ]; then
    fail "Secondary database is $secondary_status, expected available"
  fi
  if ! has_no_replication_source "$secondary_replicates_from"; then
    fail "Secondary database still replicates from $secondary_replicates_from, expected a standalone writer"
  fi
  if [ "$secondary_multi_az" != "True" ]; then
    fail "Secondary database is not Multi-AZ"
  fi
}

# waits through task recycling until primary is healthy across both AZs.
wait_primary_recovered() {
  local deadline=$(( $(date -u +%s) + WAIT_TIMEOUT ))
  local status
  while [ "$(date -u +%s)" -lt "$deadline" ]; do
    status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
      "$WORKLOAD_URL/healthz" || true)"
    if [ "$status" = "200" ] && jq -e --arg region "$PRIMARY_REGION" '
      any(.regions[];
        .region == $region and .compute.desired == 2 and .compute.running == 2
        and (.compute.availability_zones | length) == 2
        and .database.available and .database.multi_az)' \
      >/dev/null <<<"$(topology_json || echo '{"regions":[]}')"; then
      return 0
    fi
    sleep 10
  done
  fail "primary did not return to two healthy tasks across two AZs within ${WAIT_TIMEOUT}s"
}

# emits the secondary writer ARN consumed by reverse-replication plans.
emit_secondary_writer_arn() {
  aws rds describe-db-instances \
    --region "$SECONDARY_REGION" \
    --db-instance-identifier "$SECONDARY_DATABASE" \
    --query 'DBInstances[0].DBInstanceArn' --output text
}

case "${1:-}" in
  route53-delegation) guard_route53_delegation ;;
  no-failback) guard_no_failback ;;
  no-reverse-replication) guard_no_reverse_replication ;;
  primary-standalone-writer) guard_primary_standalone_writer ;;
  primary-reverse-replica) guard_primary_reverse_replica ;;
  primary-multi-az-writer) guard_primary_multi_az_writer ;;
  primary-serving-traffic) guard_primary_serving_traffic ;;
  secondary-pilot-light) guard_secondary_pilot_light ;;
  safety-snapshot) guard_safety_snapshot "${2:-}" ;;
  wait-primary-recovered) wait_primary_recovered ;;
  secondary-writer-arn) emit_secondary_writer_arn ;;
  *)
    echo "usage: $0 {route53-delegation|no-failback|no-reverse-replication|primary-standalone-writer|primary-reverse-replica|primary-multi-az-writer|primary-serving-traffic|secondary-pilot-light|safety-snapshot <id>|wait-primary-recovered|secondary-writer-arn}" >&2
    exit 2
    ;;
esac
