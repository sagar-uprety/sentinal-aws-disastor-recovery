#!/usr/bin/env bash
# Reports phase timing and row-based RPO for the current drill only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/drill-lib.sh"

if [ "${1:-}" = "record-traffic-switch" ]; then
  echo "ERROR: manual traffic timestamps are disabled. Use switch-traffic.sh so ARC state, authoritative DNS, and DR traffic are verified." >&2
  exit 1
fi

if [ ! -f "$DRILL_LOG" ]; then
  echo "No drill log at $DRILL_LOG." >&2
  exit 1
fi

current_log="$(mktemp)"
trap 'rm -f "$current_log"' EXIT
awk -F'\t' '
  $1 == "drill_started" { delete lines; count = 0 }
  { lines[++count] = $0 }
  END { for (i = 1; i <= count; i++) print lines[i] }
' "$DRILL_LOG" >"$current_log"

event_ts() {
  awk -F'\t' -v event="$1" '$1 == event { value = $2 } END { print value }' "$current_log"
}

require_event() {
  local timestamp
  timestamp="$(event_ts "$1")"
  if [ -z "$timestamp" ]; then
    echo "ERROR: current drill is missing $1." >&2
    exit 1
  fi
}

duration() {
  printf '%s' "$(( $(to_epoch "$2") - $(to_epoch "$1") ))"
}

for event in outage_confirmed failover_invoked replica_promoted dr_service_stable dr_targets_healthy dr_write_verified traffic_switch_requested traffic_verified_dr primary_last_check dr_pre_outage_last_check replica_lag_seconds; do
  require_event "$event"
done

disaster_ts="$(event_ts disaster_declared)"
outage_ts="$(event_ts outage_confirmed)"
invoked_ts="$(event_ts failover_invoked)"
promoted_ts="$(event_ts replica_promoted)"
stable_ts="$(event_ts dr_service_stable)"
healthy_ts="$(event_ts dr_targets_healthy)"
write_ts="$(event_ts dr_write_verified)"
switch_requested_ts="$(event_ts traffic_switch_requested)"
verified_ts="$(event_ts traffic_verified_dr)"
primary_last_check="$(event_ts primary_last_check)"
dr_last_check="$(event_ts dr_pre_outage_last_check)"
replica_lag="$(event_ts replica_lag_seconds)"

rto_seconds="$(duration "$outage_ts" "$verified_ts")"
automation_seconds="$(duration "$invoked_ts" "$write_ts")"
rpo_seconds="$(duration "$dr_last_check" "$primary_last_check")"
if [ "$rpo_seconds" -lt 0 ]; then
  echo "ERROR: row-based RPO is negative; target rows are not comparable." >&2
  exit 1
fi

cat <<EOF
=== Recovery timeline ===
Disaster declared:         ${disaster_ts:-not recorded}
Outage confirmed:          $outage_ts
Failover invoked:          $invoked_ts
Replica promoted:          $promoted_ts
DR service stable:         $stable_ts
Two ALB targets healthy:   $healthy_ts
Fresh DR write verified:   $write_ts
ARC switch requested:      $switch_requested_ts
Public DR traffic verified:$verified_ts

Detection to invocation:   $(duration "$outage_ts" "$invoked_ts")s
Replica promotion phase:   $(duration "$invoked_ts" "$promoted_ts")s
Task startup phase:        $(duration "$promoted_ts" "$stable_ts")s
Target health phase:       $(duration "$stable_ts" "$healthy_ts")s
Write verification phase:  $(duration "$healthy_ts" "$write_ts")s
Routing verification phase:$(duration "$switch_requested_ts" "$verified_ts")s

End-to-end RTO:            ${rto_seconds}s
Automation duration:       ${automation_seconds}s

=== Replica-promotion RPO ===
Newest primary target row before outage: $primary_last_check
Newest matching pre-outage row in DR:    $dr_last_check
Row-based observed RPO:                  ${rpo_seconds}s
Pre-promotion ReplicaLag maximum:        ${replica_lag}s
EOF
