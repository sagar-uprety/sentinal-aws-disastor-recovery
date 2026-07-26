#!/usr/bin/env bash

DRILL_LOG="${DRILL_LOG:-./drill-events.log}"
LINK_TOKEN_PARAMETER="${LINK_TOKEN_PARAMETER:-/sentinel-aws-dr/prod/link-create-token}"
MONITOR_EVENT_REGION="${MONITOR_EVENT_REGION:-eu-west-1}"
MONITOR_EVENT_TABLE="${MONITOR_EVENT_TABLE:-sentinel-aws-dr-monitoring-checks}"

publish_monitor_event() {
  local event="$1" timestamp="$2" value="${3:-}" item suffix
  suffix="$(printf '%05d' "$RANDOM")"
  item="$(jq -cn \
    --arg event "$event" \
    --arg pk "EVENTS" \
    --arg sk "EVENT#${timestamp}#${suffix}#${event}" \
    --arg timestamp "$timestamp" \
    --arg value "$value" \
    '{pk:{S:$pk},sk:{S:$sk},event:{S:$event},timestamp:{S:$timestamp},value:{S:$value}}')"
  aws dynamodb put-item \
    --region "$MONITOR_EVENT_REGION" \
    --table-name "$MONITOR_EVENT_TABLE" \
    --item "$item" \
    >/dev/null
}

log_event() {
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\t%s\n' "$1" "$timestamp" >>"$DRILL_LOG"
  publish_monitor_event "$1" "$timestamp"
}

record_event_at() {
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\t%s\n' "$1" "$2" >>"$DRILL_LOG"
  publish_monitor_event "$1" "$timestamp" "$2"
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
