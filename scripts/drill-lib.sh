#!/usr/bin/env bash

DRILL_LOG="${DRILL_LOG:-./drill-events.log}"
LINK_TOKEN_PARAMETER="${LINK_TOKEN_PARAMETER:-/sentinel-aws-dr/prod/link-create-token}"

log_event() {
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\t%s\n' "$1" "$timestamp" >>"$DRILL_LOG"
}

record_event_at() {
  printf '%s\t%s\n' "$1" "$2" >>"$DRILL_LOG"
}

current_event_ts() {
  awk -F'\t' -v event="$1" '
    $1 == "drill_started" { found = 1; value = "" }
    found && $1 == event { value = $2 }
    END { print value }
  ' "$DRILL_LOG" 2>/dev/null
}

require_current_event() {
  local timestamp
  timestamp="$(current_event_ts "$1")"
  if [ -z "$timestamp" ]; then
    echo "ERROR: current drill has no $1 event in $DRILL_LOG." >&2
    exit 1
  fi
}

to_epoch() {
  local clean="${1%Z}"
  clean="${clean%+00:00}"
  clean="${clean%%.*}"
  date -u -j -f "%Y-%m-%dT%H:%M:%S" "$clean" +%s 2>/dev/null || date -u -d "${clean}Z" +%s
}

create_short_link_direct() {
  local region="$1" host="$2" alb_dns="$3" slug="$4" destination="$5" token body
  token="$(aws ssm get-parameter --region "$region" --name "$LINK_TOKEN_PARAMETER" --with-decryption --query 'Parameter.Value' --output text)"
  body="$(jq -cn --arg slug "$slug" --arg destination "$destination" '{slug:$slug,destination_url:$destination}')"
  curl --fail-with-body --silent --show-error \
    --connect-to "${host}:443:${alb_dns}:443" \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$token") \
    --header "Content-Type: application/json" \
    --request POST \
    --data "$body" \
    "https://${host}/links"
}

list_short_links_direct() {
  local host="$1" alb_dns="$2"
  curl --fail --silent --show-error \
    --connect-to "${host}:443:${alb_dns}:443" \
    "https://${host}/links"
}

require_short_link_direct() {
  local host="$1" alb_dns="$2" slug="$3" links
  links="$(list_short_links_direct "$host" "$alb_dns")"
  jq -e --arg slug "$slug" 'any(.[]; .slug == $slug)' >/dev/null <<<"$links"
}

# Verifies every slug in a comma-separated list exists in host's current link
# list, fetching /links once rather than once per slug. A single known-slug
# check only proves one write survived; this proves every write present on
# primary immediately before the outage survived, not just a sample of one.
# On success, prints nothing and returns 0. On failure, prints the missing
# slugs (comma-separated) to stdout and returns 1.
require_all_short_links_direct() {
  local host="$1" alb_dns="$2" slugs_csv="$3" links missing
  links="$(list_short_links_direct "$host" "$alb_dns")"
  missing="$(jq -r --arg slugs "$slugs_csv" '
    ($slugs | split(",") | map(select(length > 0))) as $expected
    | ([.[].slug]) as $present
    | ($expected - $present) | join(",")
  ' <<<"$links")"
  if [ -n "$missing" ]; then
    echo "$missing"
    return 1
  fi
  return 0
}
