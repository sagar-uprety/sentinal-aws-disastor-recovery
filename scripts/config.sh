#!/usr/bin/env bash
# shares project, region, resource, and domain constants across scripts.

readonly PROJECT_NAME="${PROJECT_NAME:-pilotlight}"
readonly PRIMARY_REGION="${PRIMARY_REGION:-eu-central-1}"
readonly SECONDARY_REGION="${SECONDARY_REGION:-eu-west-1}"
readonly BASE_DOMAIN="${BASE_DOMAIN:-pilotlight.sagaruprety.com.np}"
# shellcheck disable=SC2034 # consumed by whichever script sources this file
readonly PRIMARY_RESOURCE_NAME="${PROJECT_NAME}-primary"
# shellcheck disable=SC2034 # consumed by whichever script sources this file
readonly SECONDARY_RESOURCE_NAME="${PROJECT_NAME}-secondary"
# shellcheck disable=SC2034 # consumed by whichever script sources this file
readonly WORKLOAD_HOST="shortener.${BASE_DOMAIN}"
# shellcheck disable=SC2034 # consumed by whichever script sources this file
readonly SENTRY_HOST="sentry.${BASE_DOMAIN}"
