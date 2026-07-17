#!/usr/bin/env bash
# Reads the tab-separated event log written by simulate-disaster.sh and
# failover.sh, then prints measured RTO (and the operator-invocation-only
# portion of it) and an observed RPO derived from the newest pre-disaster
# check row still present in DR after promotion.
set -euo pipefail

DR_REGION="eu-west-1"
DRILL_LOG="${DRILL_LOG:-./drill-events.log}"

if [ ! -f "$DRILL_LOG" ]; then
  echo "No drill log at ${DRILL_LOG}. Run simulate-disaster.sh and failover.sh first." >&2
  exit 1
fi

event_ts() {
  # Last matching timestamp for the given event name, empty if absent.
  awk -F'\t' -v e="$1" '$1 == e { ts = $2 } END { print ts }' "$DRILL_LOG"
}

to_epoch() {
  # Strip the trailing Z and any fractional seconds (e.g. from Postgres
  # timestamptz JSON output) before parsing -- BSD date's -j -f requires an
  # exact format match and silently fails otherwise, and the GNU fallback
  # doesn't exist on macOS, so an untrimmed timestamp broke this on both
  # branches at once.
  local clean="${1%Z}"
  clean="${clean%%.*}"
  date -u -j -f "%Y-%m-%dT%H:%M:%S" "$clean" +%s 2>/dev/null || date -u -d "${clean}Z" +%s
}

disaster_ts="$(event_ts disaster_declared)"
invoked_ts="$(event_ts failover_invoked)"
verified_ts="$(event_ts dr_write_verified)"
switched_ts="$(event_ts traffic_switched)"

if [ -z "$disaster_ts" ] || [ -z "$verified_ts" ]; then
  echo "Log is missing disaster_declared or dr_write_verified; drill is incomplete." >&2
  exit 1
fi

rto_end_ts="${switched_ts:-$verified_ts}"
rto_seconds=$(( $(to_epoch "$rto_end_ts") - $(to_epoch "$disaster_ts") ))
automation_seconds=$(( $(to_epoch "$verified_ts") - $(to_epoch "$invoked_ts") ))

echo "=== RTO ==="
echo "Disaster declared:        ${disaster_ts}"
[ -n "$switched_ts" ] && echo "Traffic switched:         ${switched_ts}"
echo "DR write verified:        ${verified_ts}"
echo "End-to-end RTO:           ${rto_seconds}s"
echo "Operator-invocation automation duration (failover_invoked -> dr_write_verified): ${automation_seconds}s"

echo
echo "=== RPO ==="
dr_alb_dns="$(aws elbv2 describe-load-balancers \
  --region "$DR_REGION" \
  --names "sentinel-aws-dr-dr-alb" \
  --query 'LoadBalancers[0].DNSName' --output text)"

# Newest check row timestamp DR is currently serving. Right after promotion
# and before the app resumes writing new checks, this is the newest
# pre-disaster row that survived -- i.e. the data-loss window.
newest_row_ts="$(curl -sS "http://${dr_alb_dns}/status" | jq -r '[.[].last_checked] | max')"
echo "Newest row present in DR: ${newest_row_ts}"

if [ "$(to_epoch "$newest_row_ts")" -le "$(to_epoch "$disaster_ts")" ]; then
  rpo_seconds=$(( $(to_epoch "$disaster_ts") - $(to_epoch "$newest_row_ts") ))
  echo "Observed RPO:              ${rpo_seconds}s"
else
  echo "Newest DR row is at or after disaster_declared: DR had fully caught up, RPO ~0s."
fi
