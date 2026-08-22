#!/usr/bin/env bash
# shares append-only event evidence and direct short-link helpers across drill steps.

readonly DRILL_LOG="${DRILL_LOG:-./drill-events.log}"
readonly LINK_TOKEN_PARAMETER="${LINK_TOKEN_PARAMETER:-/${PROJECT_NAME}/prod/link-create-token}"

# appends a UTC event timestamp used to order drill phases.
log_event() {
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\t%s\n' "$1" "$timestamp" >>"$DRILL_LOG"
}

# stores measured evidence or resource identifiers instead of the current time.
record_event_at() {
  printf '%s\t%s\n' "$1" "$2" >>"$DRILL_LOG"
}

# reads only the latest drill segment so stale events cannot satisfy current guards.
current_event_ts() {
  awk -F'\t' -v event="$1" '
    $1 == "drill_started" { found = 1; value = "" }
    found && $1 == event { value = $2 }
    END { print value }
  ' "$DRILL_LOG" 2>/dev/null
}

# stops a later phase unless its prerequisite exists in the current drill.
require_current_event() {
  local timestamp
  timestamp="$(current_event_ts "$1")"
  if [ -z "$timestamp" ]; then
    echo "error: current drill has no $1 event in $DRILL_LOG" >&2
    exit 1
  fi
}

# normalizes the two empty replication-source values returned by the AWS CLI.
replica_source_is_empty() {
  [ -z "${1:-}" ] || [ "$1" = "None" ]
}

# supports both BSD and GNU date when converting AWS timestamps.
to_epoch() {
  local clean="${1%Z}"
  clean="${clean%+00:00}"
  clean="${clean%%.*}"
  date -u -j -f "%Y-%m-%dT%H:%M:%S" "$clean" +%s 2>/dev/null || date -u -d "${clean}Z" +%s
}

# bypasses public DNS while preserving TLS hostname validation against a chosen ALB.
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

# reads links from a chosen ALB without depending on current Route 53 routing.
list_short_links_direct() {
  local host="$1" alb_dns="$2"
  curl --fail --silent --show-error \
    --connect-to "${host}:443:${alb_dns}:443" \
    "https://${host}/links"
}

# confirms one expected write reached the selected regional database.
require_short_link_direct() {
  local host="$1" alb_dns="$2" slug="$3" links
  links="$(list_short_links_direct "$host" "$alb_dns")"
  jq -e --arg slug "$slug" 'any(.[]; .slug == $slug)' >/dev/null <<<"$links"
}

# verifies every pre-outage slug in one request and prints any missing slugs.
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
