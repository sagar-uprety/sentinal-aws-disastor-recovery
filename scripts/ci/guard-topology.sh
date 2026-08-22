#!/usr/bin/env bash
# centralizes topology assertions used on both sides of protected workflow gates.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=../config.sh
source "$SCRIPT_DIR/../config.sh"

readonly PROD_DATABASE="$PROD_RESOURCE_NAME"
readonly DR_DATABASE="$DR_RESOURCE_NAME"
readonly DR_CLUSTER="$DR_RESOURCE_NAME"
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

# keeps monitor reads consistent across guards that inspect reported topology.
topology_json() {
  curl --fail --show-error --silent "https://monitor.${BASE_DOMAIN}/topology"
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
  local prod_source dr_source
  prod_source="$(replica_source_of "$PRIMARY_REGION" "$PROD_DATABASE")"
  dr_source="$(replica_source_of "$DR_REGION" "$DR_DATABASE")"
  if [ "$prod_source" = "MISSING" ] && [ "$dr_source" = "MISSING" ]; then
    return
  fi
  [ "$prod_source" != "MISSING" ] || fail "prod database is missing while DR still exists"
  is_unset "$prod_source" || fail "prod is a DR replica; database topology is in failback, use recovery.yml"
  [ "$dr_source" != "MISSING" ] || return
  if is_unset "$dr_source"; then
    fail "DR is a standalone writer; database topology is in failback, use recovery.yml"
  fi
}

# permits missing DR during destroy while still blocking reverse replication.
guard_no_reverse_replication() {
  local prod_source
  prod_source="$(replica_source_of "$PRIMARY_REGION" "$PROD_DATABASE")"
  [ "$prod_source" != "MISSING" ] || return
  is_unset "$prod_source" || fail "prod is still a DR replica; complete recovery.yml failback-reset before destroy"
}

# requires prod to be available and detached from every replication source.
guard_prod_standalone_writer() {
  local status source
  read -r status source <<<"$(aws rds describe-db-instances \
    --region "$PRIMARY_REGION" \
    --db-instance-identifier "$PROD_DATABASE" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
  [ "$status" = "available" ] || fail "prod database is $status, expected available"
  is_unset "$source" || fail "prod database still replicates from $source, expected a standalone writer"
}

# adds the production durability requirement used after failback promotion.
guard_prod_multi_az_writer() {
  local multi_az
  guard_prod_standalone_writer
  multi_az="$(aws rds describe-db-instances \
    --region "$PRIMARY_REGION" \
    --db-instance-identifier "$PROD_DATABASE" \
    --query 'DBInstances[0].MultiAZ' --output text)"
  [ "$multi_az" = "True" ] || fail "prod database is not Multi-AZ"
}

# verifies resting pilot-light topology before dependent operations continue.
guard_dr_pilot_light() {
  local desired source
  desired="$(aws ecs describe-services \
    --region "$DR_REGION" --cluster "$DR_CLUSTER" --services "$DR_CLUSTER" \
    --query 'services[0].desiredCount' --output text)"
  source="$(replica_source_of "$DR_REGION" "$DR_DATABASE")"
  [ "$desired" = "0" ] || fail "DR desired count is $desired, expected 0 at rest"
  if is_unset "$source"; then
    fail "DR database is a standalone writer, expected a replica of prod"
  fi
  [[ "$source" == *"$PROD_DATABASE"* ]] || fail "DR database replicates from $source, expected $PROD_DATABASE"
}

# prevents DR reset until prod is serving from an available Multi-AZ writer.
guard_prod_serving_traffic() {
  curl --fail --show-error --silent "https://shortener.${BASE_DOMAIN}/healthz" >/dev/null ||
    fail "prod workload is not serving /healthz"
  jq -e --arg region "$PRIMARY_REGION" \
    'any(.regions[]; .region == $region and .database.available and .database.multi_az)' \
    >/dev/null <<<"$(topology_json)" ||
    fail "monitor topology does not report prod as available and Multi-AZ"
  guard_prod_standalone_writer
}

# requires a fresh encrypted DR snapshot before destructive prod reconstruction.
guard_safety_snapshot() {
  local snapshot_id="${1:?safety-snapshot requires a snapshot id}"
  local status source encrypted created age
  local dr_status dr_source dr_multi_az

  [[ "$snapshot_id" == "${DR_DATABASE}-pre-failback-"* ]] ||
    fail "snapshot $snapshot_id is not a ${DR_DATABASE}-pre-failback-* snapshot"

  read -r status source encrypted created <<<"$(aws rds describe-db-snapshots \
    --region "$DR_REGION" \
    --db-snapshot-identifier "$snapshot_id" \
    --query 'DBSnapshots[0].[Status,DBInstanceIdentifier,Encrypted,SnapshotCreateTime]' --output text)"
  age=$(( $(date -u +%s) - $(date -u -d "$created" +%s) ))
  [ "$status" = "available" ] || fail "snapshot is $status, expected available"
  [ "$source" = "$DR_DATABASE" ] || fail "snapshot is of $source, expected $DR_DATABASE"
  [ "$encrypted" = "True" ] || fail "snapshot is not encrypted"
  [ "$age" -le "$SNAPSHOT_MAX_AGE" ] || fail "snapshot is ${age}s old, exceeds ${SNAPSHOT_MAX_AGE}s"

  read -r dr_status dr_source dr_multi_az <<<"$(aws rds describe-db-instances \
    --region "$DR_REGION" \
    --db-instance-identifier "$DR_DATABASE" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier,MultiAZ]' --output text)"
  [ "$dr_status" = "available" ] || fail "DR database is $dr_status, expected available"
  is_unset "$dr_source" || fail "DR database still replicates from $dr_source, expected a standalone writer"
  [ "$dr_multi_az" = "True" ] || fail "DR database is not Multi-AZ"
}

# waits through task recycling until prod is healthy across both AZs.
wait_prod_recovered() {
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
  fail "prod did not return to two healthy tasks across two AZs within ${WAIT_TIMEOUT}s"
}

# emits the DR writer ARN consumed by reverse-replication plans.
emit_dr_writer_arn() {
  aws rds describe-db-instances \
    --region "$DR_REGION" \
    --db-instance-identifier "$DR_DATABASE" \
    --query 'DBInstances[0].DBInstanceArn' --output text
}

case "${1:-}" in
  route53-delegation) guard_route53_delegation ;;
  no-failback) guard_no_failback ;;
  no-reverse-replication) guard_no_reverse_replication ;;
  prod-standalone-writer) guard_prod_standalone_writer ;;
  prod-multi-az-writer) guard_prod_multi_az_writer ;;
  prod-serving-traffic) guard_prod_serving_traffic ;;
  dr-pilot-light) guard_dr_pilot_light ;;
  safety-snapshot) guard_safety_snapshot "${2:-}" ;;
  wait-prod-recovered) wait_prod_recovered ;;
  dr-writer-arn) emit_dr_writer_arn ;;
  *)
    echo "usage: $0 {route53-delegation|no-failback|no-reverse-replication|prod-standalone-writer|prod-multi-az-writer|prod-serving-traffic|dr-pilot-light|safety-snapshot <id>|wait-prod-recovered|dr-writer-arn}" >&2
    exit 2
    ;;
esac
