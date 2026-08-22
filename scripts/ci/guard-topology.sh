#!/usr/bin/env bash
# centralizes topology assertions used on both sides of protected workflow gates.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=../config.sh
source "$SCRIPT_DIR/../config.sh"

readonly PRIMARY_DATABASE="$PRIMARY_RESOURCE_NAME"
readonly SECONDARY_DATABASE="$SECONDARY_RESOURCE_NAME"
readonly SECONDARY_CLUSTER="$SECONDARY_RESOURCE_NAME"
# bounds pre-failback safety snapshot age in seconds.
readonly SNAPSHOT_MAX_AGE=21600
# bounds post-repair recovery polling in seconds.
readonly WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"

# gives every workflow guard a consistent fatal error format.
fail() {
  echo "error: guard-topology: $1" >&2
  exit 1
}

# handles both values the RDS CLI uses for no replication source.
is_unset() {
  [ -z "$1" ] || [ "$1" = "None" ]
}

# returns MISSING for absent databases while preserving real AWS API failures.
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
  curl --fail --show-error --silent "https://sentry.${BASE_DOMAIN}/topology"
}

# ensures public DNS exposes every Route 53 nameserver required by ACM and failover records.
guard_route53_delegation() {
  local zone_id nameserver
  zone_id="$(aws route53 list-hosted-zones-by-name \
    --dns-name "${BASE_DOMAIN}." \
    --query "HostedZones[?Name=='${BASE_DOMAIN}.'].Id | [0]" --output text)"
  for nameserver in $(aws route53 get-hosted-zone --id "$zone_id" \
    --query 'DelegationSet.NameServers' --output text); do
    dig +short NS "$BASE_DOMAIN" | grep -Fxq "${nameserver%.}." ||
      fail "missing public delegation to $nameserver; apply bootstrap and update Cloudflare first"
  done
}

# blocks normal applies while reverse replication shows failback is active.
guard_no_failback() {
  local primary_source secondary_source
  primary_source="$(replica_source_of "$PRIMARY_REGION" "$PRIMARY_DATABASE")"
  secondary_source="$(replica_source_of "$SECONDARY_REGION" "$SECONDARY_DATABASE")"
  if [ "$primary_source" = "MISSING" ] && [ "$secondary_source" = "MISSING" ]; then
    return
  fi
  [ "$primary_source" != "MISSING" ] || fail "primary database is missing while secondary still exists"
  is_unset "$primary_source" || fail "primary is a secondary replica; database topology is in failback, use recovery.yml"
  [ "$secondary_source" != "MISSING" ] || return
  if is_unset "$secondary_source"; then
    fail "Secondary is a standalone writer; database topology is in failback, use recovery.yml"
  fi
}

# permits missing secondary during destroy while still blocking reverse replication.
guard_no_reverse_replication() {
  local primary_source
  primary_source="$(replica_source_of "$PRIMARY_REGION" "$PRIMARY_DATABASE")"
  [ "$primary_source" != "MISSING" ] || return
  is_unset "$primary_source" || fail "primary is still a secondary replica; complete recovery.yml failback-reset before destroy"
}

# requires primary to be available and detached from every replication source.
guard_primary_standalone_writer() {
  local status source
  read -r status source <<<"$(aws rds describe-db-instances \
    --region "$PRIMARY_REGION" \
    --db-instance-identifier "$PRIMARY_DATABASE" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
  [ "$status" = "available" ] || fail "primary database is $status, expected available"
  is_unset "$source" || fail "primary database still replicates from $source, expected a standalone writer"
}

# adds the production durability requirement used after failback promotion.
guard_primary_multi_az_writer() {
  local multi_az
  guard_primary_standalone_writer
  multi_az="$(aws rds describe-db-instances \
    --region "$PRIMARY_REGION" \
    --db-instance-identifier "$PRIMARY_DATABASE" \
    --query 'DBInstances[0].MultiAZ' --output text)"
  [ "$multi_az" = "True" ] || fail "primary database is not Multi-AZ"
}

# verifies resting pilot-light topology before dependent operations continue.
guard_secondary_pilot_light() {
  local desired source
  desired="$(aws ecs describe-services \
    --region "$SECONDARY_REGION" --cluster "$SECONDARY_CLUSTER" --services "$SECONDARY_CLUSTER" \
    --query 'services[0].desiredCount' --output text)"
  source="$(replica_source_of "$SECONDARY_REGION" "$SECONDARY_DATABASE")"
  [ "$desired" = "0" ] || fail "Secondary desired count is $desired, expected 0 at rest"
  if is_unset "$source"; then
    fail "Secondary database is a standalone writer, expected a replica of primary"
  fi
  [[ "$source" == *"$PRIMARY_DATABASE"* ]] || fail "Secondary database replicates from $source, expected $PRIMARY_DATABASE"
}

# prevents secondary reset until primary is serving from an available Multi-AZ writer.
guard_primary_serving_traffic() {
  curl --fail --show-error --silent "https://shortener.${BASE_DOMAIN}/healthz" >/dev/null ||
    fail "primary workload is not serving /healthz"
  jq -e --arg region "$PRIMARY_REGION" \
    'any(.regions[]; .region == $region and .database.available and .database.multi_az)' \
    >/dev/null <<<"$(topology_json)" ||
    fail "sentry topology does not report primary as available and Multi-AZ"
  guard_primary_standalone_writer
}

# requires a fresh encrypted secondary snapshot before destructive primary reconstruction.
guard_safety_snapshot() {
  local snapshot_id="${1:?safety-snapshot requires a snapshot id}"
  local status source encrypted created age
  local secondary_status secondary_source secondary_multi_az

  [[ "$snapshot_id" == "${SECONDARY_DATABASE}-pre-failback-"* ]] ||
    fail "snapshot $snapshot_id is not a ${SECONDARY_DATABASE}-pre-failback-* snapshot"

  read -r status source encrypted created <<<"$(aws rds describe-db-snapshots \
    --region "$SECONDARY_REGION" \
    --db-snapshot-identifier "$snapshot_id" \
    --query 'DBSnapshots[0].[Status,DBInstanceIdentifier,Encrypted,SnapshotCreateTime]' --output text)"
  age=$(( $(date -u +%s) - $(date -u -d "$created" +%s) ))
  [ "$status" = "available" ] || fail "snapshot is $status, expected available"
  [ "$source" = "$SECONDARY_DATABASE" ] || fail "snapshot is of $source, expected $SECONDARY_DATABASE"
  [ "$encrypted" = "True" ] || fail "snapshot is not encrypted"
  [ "$age" -le "$SNAPSHOT_MAX_AGE" ] || fail "snapshot is ${age}s old, exceeds ${SNAPSHOT_MAX_AGE}s"

  read -r secondary_status secondary_source secondary_multi_az <<<"$(aws rds describe-db-instances \
    --region "$SECONDARY_REGION" \
    --db-instance-identifier "$SECONDARY_DATABASE" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier,MultiAZ]' --output text)"
  [ "$secondary_status" = "available" ] || fail "Secondary database is $secondary_status, expected available"
  is_unset "$secondary_source" || fail "Secondary database still replicates from $secondary_source, expected a standalone writer"
  [ "$secondary_multi_az" = "True" ] || fail "Secondary database is not Multi-AZ"
}

# waits through task recycling until primary is healthy across both AZs.
wait_primary_recovered() {
  local deadline=$(( $(date -u +%s) + WAIT_TIMEOUT ))
  local status
  while [ "$(date -u +%s)" -lt "$deadline" ]; do
    status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
      "https://shortener.${BASE_DOMAIN}/healthz" || true)"
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
  primary-multi-az-writer) guard_primary_multi_az_writer ;;
  primary-serving-traffic) guard_primary_serving_traffic ;;
  secondary-pilot-light) guard_secondary_pilot_light ;;
  safety-snapshot) guard_safety_snapshot "${2:-}" ;;
  wait-primary-recovered) wait_primary_recovered ;;
  secondary-writer-arn) emit_secondary_writer_arn ;;
  *)
    echo "usage: $0 {route53-delegation|no-failback|no-reverse-replication|primary-standalone-writer|primary-multi-az-writer|primary-serving-traffic|secondary-pilot-light|safety-snapshot <id>|wait-primary-recovered|secondary-writer-arn}" >&2
    exit 2
    ;;
esac
