#!/usr/bin/env bash
# shares append-only event evidence and direct short-link helpers across drill steps.

readonly DRILL_LOG="${DRILL_LOG:-./drill-events.log}"
# how stale a ReplicaLag datapoint may be and still count as current evidence.
readonly REPLICA_LAG_MAX_AGE_SECONDS=180
# PROJECT_NAME comes from the sourcing script's config.sh, not from this file.
readonly LINK_TOKEN_PARAMETER="${LINK_TOKEN_PARAMETER:-/${PROJECT_NAME}/primary/link-create-token}"

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
current_drill_event_ts() {
  awk -F'\t' -v event="$1" '
    $1 == "drill_started" { found = 1; value = "" }
    found && $1 == event { value = $2 }
    END { print value }
  ' "$DRILL_LOG" 2>/dev/null
}

# stops a later phase unless its prerequisite exists in the current drill.
require_current_event() {
  local timestamp
  timestamp="$(current_drill_event_ts "$1")"
  if [ -z "$timestamp" ]; then
    echo "error: current drill has no $1 event in $DRILL_LOG" >&2
    exit 1
  fi
}

# prints status, replication source, Multi-AZ; read all three or the last absorbs the rest.
db_topology() {
  aws rds describe-db-instances \
    --region "$1" \
    --db-instance-identifier "$2" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier,MultiAZ]' --output text
}

# prints two tab-separated fields: desired count, running count.
ecs_service_counts() {
  aws ecs describe-services \
    --region "$1" \
    --cluster "$2" \
    --services "$3" \
    --query 'services[0].[desiredCount,runningCount]' --output text
}

# the load balancer's own view, which lags ECS task state.
healthy_target_count() {
  aws elbv2 describe-target-health \
    --region "$1" \
    --target-group-arn "$2" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text
}

# lets a check target one specific region regardless of where Route 53 points.
alb_dns_name() {
  aws elbv2 describe-load-balancers \
    --region "$1" \
    --names "$2" \
    --query 'LoadBalancers[0].DNSName' --output text
}

# target-health calls accept only the ARN, never the target group's name.
target_group_arn_for() {
  aws elbv2 describe-target-groups \
    --region "$1" \
    --names "$2" \
    --query 'TargetGroups[0].TargetGroupArn' --output text
}

# tasks stacked in one AZ would pass a count check but not survive losing that AZ.
require_task_az_spread() {
  local region="$1" cluster="$2" service="$3" task_arns az_count
  read -r -a task_arns <<<"$(aws ecs list-tasks \
    --region "$region" \
    --cluster "$cluster" \
    --service-name "$service" \
    --desired-status RUNNING \
    --query 'taskArns' --output text)"
  if [ "${#task_arns[@]}" -ne "$WORKLOAD_DESIRED_COUNT" ]; then
    return 1
  fi
  az_count="$(aws ecs describe-tasks \
    --region "$region" \
    --cluster "$cluster" \
    --tasks "${task_arns[@]}" \
    --query 'tasks[].availabilityZone' --output json | jq 'unique | length')"
  [ "$az_count" -eq "$WORKLOAD_AZ_COUNT" ]
}

# fetches the newest maximum ReplicaLag datapoint from a five-minute window.
latest_replica_lag_json() {
  local region="$1" database="$2" start
  # BSD date first, GNU date as fallback, so drills run on a laptop and a CI runner alike.
  start="$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
  aws cloudwatch get-metric-statistics \
    --region "$region" \
    --namespace AWS/RDS \
    --metric-name ReplicaLag \
    --dimensions Name=DBInstanceIdentifier,Value="$database" \
    --start-time "$start" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 60 --statistics Maximum \
    --query 'sort_by(Datapoints, &Timestamp)[-1]' --output json
}

# prints "lag<TAB>timestamp" for the newest usable ReplicaLag datapoint, or fails with a reason
# on stderr. Callers polling in a loop should silence that; a single-shot caller should show it.
fresh_replica_lag() {
  local region="$1" database="$2" data lag timestamp age
  data="$(latest_replica_lag_json "$region" "$database")"
  lag="$(jq -r '.Maximum // empty' <<<"$data")"
  timestamp="$(jq -r '.Timestamp // empty' <<<"$data")"
  # RDS reports ReplicaLag=-1 when replication is not active/determinable; treat as no evidence.
  if [ -z "$lag" ] || [ "$lag" = "-1" ] || [ -z "$timestamp" ]; then
    echo "no usable ReplicaLag datapoint for $database" >&2
    return 1
  fi
  # a stale datapoint says nothing about current lag, so it must not stand in for one.
  age=$(( $(date -u +%s) - $(to_epoch "$timestamp") ))
  if [ "$age" -gt "$REPLICA_LAG_MAX_AGE_SECONDS" ]; then
    echo "latest ReplicaLag datapoint for $database is ${age}s old" >&2
    return 1
  fi
  printf '%s\t%s\n' "$lag" "$timestamp"
}

# bash cannot compare decimals, so awk does the arithmetic and its exit status becomes the answer.
lag_within_target() {
  awk -v lag="$1" -v target="$2" 'BEGIN { exit !(lag <= target) }'
}

# bypasses public DNS while preserving TLS hostname validation against a chosen ALB.
create_short_link_direct() {
  local region="$1" host="$2" alb_dns="$3" slug="$4" destination="$5" token body
  token="$(aws ssm get-parameter --region "$region" --name "$LINK_TOKEN_PARAMETER" --with-decryption --query 'Parameter.Value' --output text)"
  body="$(jq -cn --arg slug "$slug" --arg destination "$destination" '{slug:$slug,destination_url:$destination}')"
  # --connect-to moves only the TCP target, so SNI and cert checks still use host;
  # --config keeps the bearer token out of the process list.
  curl --fail-with-body --silent --show-error \
    --connect-to "${host}:443:${alb_dns}:443" \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$token") \
    --header "Content-Type: application/json" \
    --request POST \
    --data "$body" \
    "https://${host}/links"
}

# reads links from a chosen ALB without depending on current Route 53 routing.
# limit is raised past the API default so a recorded drill slug cannot age out of the page.
list_short_links_direct() {
  local host="$1" alb_dns="$2"
  curl --fail --silent --show-error \
    --connect-to "${host}:443:${alb_dns}:443" \
    "https://${host}/links?limit=1000"
}

# confirms one expected write reached the selected regional database.
require_short_link_direct() {
  local host="$1" alb_dns="$2" slug="$3" links
  links="$(list_short_links_direct "$host" "$alb_dns")"
  jq -e --arg slug "$slug" 'any(.[]; .slug == $slug)' >/dev/null <<<"$links"
}

# checks the whole set rather than a sample, and names the missing slugs on failure.
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
