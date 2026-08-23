#!/usr/bin/env bash
# reports recovery timing and RPO evidence for the latest drill.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=../config.sh
source "$SCRIPT_DIR/../config.sh"
# shellcheck source=drill-lib.sh
source "$SCRIPT_DIR/drill-lib.sh"

# ==== PRECHECKS ====
if [ ! -f "$DRILL_LOG" ]; then
  echo "error: no drill log at $DRILL_LOG" >&2
  exit 1
fi

# ==== MAIN TASK: compute and print the RTO/RPO recovery timeline ====
# converts two UTC timestamps into elapsed seconds.
duration() {
  printf '%s' "$(( $(to_epoch "$2") - $(to_epoch "$1") ))"
}

# all-or-nothing, so an aborted drill cannot print a partial timeline as a result.
for event in disaster_declared outage_confirmed failover_invoked replica_promoted secondary_service_stable secondary_targets_healthy pre_outage_link_verified_in_secondary secondary_write_verified traffic_switch_requested_secondary traffic_verified_secondary primary_link_created_at replica_lag_seconds replica_lag_timestamp; do
  require_current_event "$event"
done

disaster_ts="$(current_drill_event_ts disaster_declared)"
outage_ts="$(current_drill_event_ts outage_confirmed)"
invoked_ts="$(current_drill_event_ts failover_invoked)"
promoted_ts="$(current_drill_event_ts replica_promoted)"
stable_ts="$(current_drill_event_ts secondary_service_stable)"
healthy_ts="$(current_drill_event_ts secondary_targets_healthy)"
link_verified_ts="$(current_drill_event_ts pre_outage_link_verified_in_secondary)"
write_ts="$(current_drill_event_ts secondary_write_verified)"
switch_requested_ts="$(current_drill_event_ts traffic_switch_requested_secondary)"
verified_ts="$(current_drill_event_ts traffic_verified_secondary)"
primary_link_created_at="$(current_drill_event_ts primary_link_created_at)"
replica_lag="$(current_drill_event_ts replica_lag_seconds)"
replica_lag_timestamp="$(current_drill_event_ts replica_lag_timestamp)"

# RTO is the user-visible outage; automation excludes detection lag and DNS propagation.
rto_seconds="$(duration "$outage_ts" "$verified_ts")"
automation_seconds="$(duration "$invoked_ts" "$write_ts")"

cat <<EOF
=== Recovery timeline ===
Disaster declared:         $disaster_ts
Outage confirmed:          $outage_ts
Failover invoked:          $invoked_ts
Replica promoted:          $promoted_ts
Secondary service stable: $stable_ts
Two ALB targets healthy:   $healthy_ts
Pre-outage link verified in secondary: $link_verified_ts
Fresh secondary write verified:   $write_ts
ARC switch requested:      $switch_requested_ts
Public secondary traffic verified: $verified_ts

Declaration phase:         $(duration "$disaster_ts" "$outage_ts")s
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
Primary-created link (created $primary_link_created_at) confirmed present in secondary at $link_verified_ts.
This confirms the pre-outage write survived promotion; it is a pass/fail boundary
check, not an elapsed-time measurement, since a replicated row's own timestamp
is identical on both sides by definition. ReplicaLag above is the real measured
RPO evidence.
EOF
