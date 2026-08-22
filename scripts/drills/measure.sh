#!/usr/bin/env bash
# reports recovery timing and RPO evidence for the latest drill.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=../config.sh
source "$SCRIPT_DIR/../config.sh"
# shellcheck source=drill-lib.sh
source "$SCRIPT_DIR/drill-lib.sh"

if [ "${1:-}" = "record-traffic-switch" ]; then
  echo "error: manual traffic timestamps are disabled; use switch-traffic.sh for verified timestamps" >&2
  exit 1
fi

if [ ! -f "$DRILL_LOG" ]; then
  echo "error: no drill log at $DRILL_LOG" >&2
  exit 1
fi

# isolates events after the latest drill_started marker before calculating metrics.
current_log="$(mktemp)"
trap 'rm -f "$current_log"' EXIT
awk -F'\t' '
  $1 == "drill_started" { delete lines; count = 0 }
  { lines[++count] = $0 }
  END { for (i = 1; i <= count; i++) print lines[i] }
' "$DRILL_LOG" >"$current_log"

# returns the latest value recorded for one event in the isolated drill.
event_ts() {
  awk -F'\t' -v event="$1" '$1 == event { value = $2 } END { print value }' "$current_log"
}

# rejects incomplete evidence instead of reporting misleading partial metrics.
require_event() {
  local timestamp
  timestamp="$(event_ts "$1")"
  if [ -z "$timestamp" ]; then
    echo "error: current drill is missing $1" >&2
    exit 1
  fi
}

# converts two UTC timestamps into elapsed seconds.
duration() {
  printf '%s' "$(( $(to_epoch "$2") - $(to_epoch "$1") ))"
}

# requires every boundary used by RTO, automation, and RPO output.
for event in disaster_declared outage_confirmed failover_invoked replica_promoted dr_service_stable dr_targets_healthy pre_outage_link_verified_in_dr dr_write_verified traffic_switch_requested_dr traffic_verified_dr primary_link_created_at replica_lag_seconds replica_lag_timestamp; do
  require_event "$event"
done

disaster_ts="$(event_ts disaster_declared)"
outage_ts="$(event_ts outage_confirmed)"
invoked_ts="$(event_ts failover_invoked)"
promoted_ts="$(event_ts replica_promoted)"
stable_ts="$(event_ts dr_service_stable)"
healthy_ts="$(event_ts dr_targets_healthy)"
link_verified_ts="$(event_ts pre_outage_link_verified_in_dr)"
write_ts="$(event_ts dr_write_verified)"
switch_requested_ts="$(event_ts traffic_switch_requested_dr)"
verified_ts="$(event_ts traffic_verified_dr)"
primary_link_created_at="$(event_ts primary_link_created_at)"
replica_lag="$(event_ts replica_lag_seconds)"
replica_lag_timestamp="$(event_ts replica_lag_timestamp)"

# measures user-visible recovery separately from failover automation runtime.
rto_seconds="$(duration "$outage_ts" "$verified_ts")"
automation_seconds="$(duration "$invoked_ts" "$write_ts")"

cat <<EOF
=== Recovery timeline ===
Disaster declared:         $disaster_ts
Outage confirmed:          $outage_ts
Failover invoked:          $invoked_ts
Replica promoted:          $promoted_ts
DR service stable:         $stable_ts
Two ALB targets healthy:   $healthy_ts
Pre-outage link verified in DR:$link_verified_ts
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
Pre-promotion ReplicaLag maximum (authoritative RPO): ${replica_lag}s
ReplicaLag datapoint timestamp:                       $replica_lag_timestamp
Prod-created link (created $primary_link_created_at) confirmed present in DR at $link_verified_ts.
This confirms the pre-outage write survived promotion; it is a pass/fail boundary
check, not an elapsed-time measurement, since a replicated row's own timestamp
is identical on both sides by definition. ReplicaLag above is the real measured
RPO evidence.
EOF
