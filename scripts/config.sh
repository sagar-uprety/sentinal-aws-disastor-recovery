#!/usr/bin/env bash
# constants plus the few helpers both drills and CI need; CI sources only this file,
# so anything drill-only (event log, link probes) belongs in drills/drill-lib.sh instead.

# config.json is the same file Terraform reads, so names and regions have one definition.
CONFIG_FILE="${CONFIG_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.json}"
readonly CONFIG_FILE

# every value below stays overridable by an environment variable of the same name.
config_value() {
  jq -er "$1" "$CONFIG_FILE" || {
    echo "error: config.sh: $1 missing from $CONFIG_FILE" >&2
    return 1
  }
}

readonly PROJECT_NAME="${PROJECT_NAME:-$(config_value .project_name)}"
readonly PRIMARY_REGION="${PRIMARY_REGION:-$(config_value .regions.primary)}"
readonly SECONDARY_REGION="${SECONDARY_REGION:-$(config_value .regions.secondary)}"
# sentry sits outside both drill regions so it survives a failover of either.
readonly SENTRY_REGION="${SENTRY_REGION:-$(config_value .regions.monitoring)}"
readonly BASE_DOMAIN="${BASE_DOMAIN:-$(config_value .base_domain)}"
# shellcheck disable=SC2034 # consumed by whichever script sources this file
readonly PRIMARY_RESOURCE_NAME="${PROJECT_NAME}-primary"
# shellcheck disable=SC2034 # consumed by whichever script sources this file
readonly SECONDARY_RESOURCE_NAME="${PROJECT_NAME}-secondary"
# mirrors var.desired_count in terraform/environments/{primary,secondary}/variables.tf.
readonly WORKLOAD_DESIRED_COUNT="${WORKLOAD_DESIRED_COUNT:-2}"
# mirrors local.azs in terraform/environments/{primary,secondary}/locals.tf.
readonly WORKLOAD_AZ_COUNT="${WORKLOAD_AZ_COUNT:-2}"
# shellcheck disable=SC2034 # consumed by whichever script sources this file
readonly WORKLOAD_HOST="shortener.${BASE_DOMAIN}"
# shellcheck disable=SC2034 # consumed by whichever script sources this file
readonly SENTRY_HOST="sentry.${BASE_DOMAIN}"
# shellcheck disable=SC2034 # consumed by whichever script sources this file
readonly WORKLOAD_URL="https://${WORKLOAD_HOST}"
# shellcheck disable=SC2034 # consumed by whichever script sources this file
readonly SENTRY_URL="https://${SENTRY_HOST}"

# RDS reports an absent source as empty or the literal "None" depending on the call.
has_no_replication_source() {
  [ -z "${1:-}" ] || [ "$1" = "None" ]
}

to_epoch() {
  # strips the zone suffix and fractional seconds, which neither date flavor parses.
  local clean="${1%Z}"
  clean="${clean%+00:00}"
  clean="${clean%%.*}"
  # BSD date first, GNU date as fallback, so drills run on a laptop and a CI runner alike.
  date -u -j -f "%Y-%m-%dT%H:%M:%S" "$clean" +%s 2>/dev/null || date -u -d "${clean}Z" +%s
}
