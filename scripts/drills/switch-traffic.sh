#!/usr/bin/env bash
# switches pre-provisioned ARC controls and verifies authoritative DNS traffic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=../config.sh
source "$SCRIPT_DIR/../config.sh"
# shellcheck source=drill-lib.sh
source "$SCRIPT_DIR/drill-lib.sh"

# the ARC configuration API is single-region; config.json's regions.arc pins where.
readonly ARC_CONTROL_REGION="${ARC_CONTROL_REGION:-$(region_for arc)}"
readonly ARC_CLUSTER_NAME="${ARC_CLUSTER_NAME:-${PROJECT_NAME}-arc}"
readonly ARC_CONTROL_PANEL_NAME="${ARC_CONTROL_PANEL_NAME:-${PROJECT_NAME}-arc}"
readonly STATUS_HOST="$WORKLOAD_HOST"
readonly HOSTED_ZONE_NAME="${BASE_DOMAIN}."
readonly TARGET="${1:-}"

# ==== PRECHECKS ====
case "$TARGET" in
initialize)
  # establishes the resting primary-on state before the first drill.
  if [ "${CONFIRM_TRAFFIC_SWITCH:-}" != "INITIALIZE" ]; then
    echo "error: set CONFIRM_TRAFFIC_SWITCH=INITIALIZE before preparing ARC controls" >&2
    exit 1
  fi
  initialize=true
  new_primary="On"
  new_secondary="Off"
  ;;
secondary)
  # requires healthy, writable secondary before moving public traffic away from primary.
  if [ "${CONFIRM_TRAFFIC_SWITCH:-}" != "SECONDARY" ]; then
    echo "error: set CONFIRM_TRAFFIC_SWITCH=SECONDARY to route traffic to secondary" >&2
    exit 1
  fi
  require_current_event "secondary_targets_healthy"
  require_current_event "secondary_write_verified"
  require_current_event "pre_outage_link_slug"
  expected_primary="On"
  expected_secondary="Off"
  new_primary="Off"
  new_secondary="On"
  target_region="$SECONDARY_REGION"
  target_alb="${SECONDARY_RESOURCE_NAME}-alb"
  verification_slug="$(current_drill_event_ts pre_outage_link_slug)"
  initialize=false
  ;;
primary)
  # requires completed failback verification before returning traffic to primary.
  if [ "${CONFIRM_TRAFFIC_SWITCH:-}" != "PRIMARY" ]; then
    echo "error: set CONFIRM_TRAFFIC_SWITCH=PRIMARY after failback verification" >&2
    exit 1
  fi
  require_current_event "failback_ready"
  expected_primary="Off"
  expected_secondary="On"
  new_primary="On"
  new_secondary="Off"
  target_region="$PRIMARY_REGION"
  target_alb="${PRIMARY_RESOURCE_NAME}-alb"
  verification_slug="$(current_drill_event_ts failback_secondary_final_link_slug)"
  initialize=false
  ;;
*)
  echo "usage: $0 {initialize|secondary|primary}" >&2
  exit 1
  ;;
esac

# name-to-ARN lookups only, so the less-available configuration API is fine here.
cluster_json="$(aws route53-recovery-control-config list-clusters \
  --region "$ARC_CONTROL_REGION" \
  --query "Clusters[?Name=='${ARC_CLUSTER_NAME}'] | [0]" --output json)"
cluster_arn="$(jq -r '.ClusterArn // empty' <<<"$cluster_json")"
if [ -z "$cluster_arn" ]; then
  echo "error: ARC cluster $ARC_CLUSTER_NAME was not found" >&2
  exit 1
fi

control_panel_arn="$(aws route53-recovery-control-config list-control-panels \
  --region "$ARC_CONTROL_REGION" \
  --cluster-arn "$cluster_arn" \
  --query "ControlPanels[?Name=='${ARC_CONTROL_PANEL_NAME}'].ControlPanelArn | [0]" --output text)"
if [ -z "$control_panel_arn" ] || [ "$control_panel_arn" = "None" ]; then
  echo "error: ARC control panel $ARC_CONTROL_PANEL_NAME was not found" >&2
  exit 1
fi

routing_controls="$(aws route53-recovery-control-config list-routing-controls \
  --region "$ARC_CONTROL_REGION" \
  --control-panel-arn "$control_panel_arn" --output json)"
primary_control_arn="$(jq -r '.RoutingControls[] | select(.Name == "primary") | .RoutingControlArn' <<<"$routing_controls")"
secondary_control_arn="$(jq -r '.RoutingControls[] | select(.Name == "secondary") | .RoutingControlArn' <<<"$routing_controls")"
if [ -z "$primary_control_arn" ] || [ -z "$secondary_control_arn" ]; then
  echo "error: primary and secondary routing controls were not found" >&2
  exit 1
fi

# collects every ARC data-plane endpoint so state reads/writes survive one unavailable region.
arc_endpoints=()
while IFS= read -r entry; do
  arc_endpoints[${#arc_endpoints[@]}]="$entry"
done < <(jq -r '.ClusterEndpoints[] | [.Endpoint, .Region] | @tsv' <<<"$cluster_json")
if [ "${#arc_endpoints[@]}" -eq 0 ]; then
  echo "error: ARC cluster has no data-plane endpoints" >&2
  exit 1
fi

# tries each endpoint until one answers; only total failure matters during an outage.
arc_get_state() {
  local control_arn="$1" endpoint region state entry
  for entry in "${arc_endpoints[@]}"; do
    IFS=$'\t' read -r endpoint region <<<"$entry"
    if state="$(aws route53-recovery-cluster \
      --endpoint-url "$endpoint" \
      --region "$region" \
      get-routing-control-state \
      --routing-control-arn "$control_arn" \
      --query 'RoutingControlState' --output text 2>/dev/null)"; then
      printf '%s\n' "$state"
      return 0
    fi
  done
  return 1
}

# sets primary_state and secondary_state, or exits; both the pre-switch guard and the
# post-switch confirmation need the same pair read the same way.
read_arc_states() {
  if ! primary_state="$(arc_get_state "$primary_control_arn")"; then
    echo "error: could not read primary routing control state from any ARC endpoint" >&2
    exit 1
  fi
  if ! secondary_state="$(arc_get_state "$secondary_control_arn")"; then
    echo "error: could not read secondary routing control state from any ARC endpoint" >&2
    exit 1
  fi
}

# an unexpected starting state means a half-applied switch or an out-of-band change.
read_arc_states
# expected_* are unset on the initialize path, where set -u would error on a read.
if [ "$initialize" != true ] && { [ "$primary_state" != "$expected_primary" ] || [ "$secondary_state" != "$expected_secondary" ]; }; then
  echo "error: ARC state is primary=$primary_state secondary=$secondary_state; expected $expected_primary/$expected_secondary" >&2
  exit 1
fi

# ==== MAIN TASK: atomically flip both ARC routing controls ====
# one call carries both states, so the pair cannot land with both On or both Off.
switch_succeeded=false
for entry in "${arc_endpoints[@]}"; do
  IFS=$'\t' read -r endpoint region <<<"$entry"
  if aws route53-recovery-cluster \
    --endpoint-url "$endpoint" \
    --region "$region" \
    update-routing-control-states \
    --update-routing-control-state-entries \
      "RoutingControlArn=$primary_control_arn,RoutingControlState=$new_primary" \
      "RoutingControlArn=$secondary_control_arn,RoutingControlState=$new_secondary" \
    >/dev/null 2>&1; then
    switch_succeeded=true
    break
  fi
done
if [ "$switch_succeeded" != true ]; then
  echo "error: all ARC data-plane endpoints rejected the atomic switch" >&2
  exit 1
fi
log_event "traffic_switch_requested_${TARGET}"

# ==== POSTCHECKS ====
# an accepted request is not a converged state, so the flip is read back.
read_arc_states
if [ "$primary_state" != "$new_primary" ] || [ "$secondary_state" != "$new_secondary" ]; then
  echo "error: ARC did not reach requested state primary=$new_primary secondary=$new_secondary" >&2
  exit 1
fi
log_event "traffic_switched"

if [ "$initialize" = true ]; then
  log_event "arc_initialized"
  echo "ARC initialized: primary=On secondary=Off."
  exit 0
fi

# queries the zone's own nameserver, since a cached resolver still answers pre-switch.
zone_id="$(aws route53 list-hosted-zones-by-name \
  --dns-name "$HOSTED_ZONE_NAME" \
  --query "HostedZones[?Name=='${HOSTED_ZONE_NAME}'].Id | [0]" --output text)"
nameserver="$(aws route53 get-hosted-zone \
  --id "$zone_id" \
  --query 'DelegationSet.NameServers[0]' --output text)"
alb_dns="$(alb_dns_name "$target_region" "$target_alb")"

# cutover counts only when DNS, health, and the expected row all agree; 36 x 5s = 3 min.
verified=false
for _ in {1..36}; do
  target_ips="$(dig +short A "$alb_dns")"
  authoritative_ips=()
  while IFS= read -r ip; do
    authoritative_ips[${#authoritative_ips[@]}]="$ip"
  done < <(dig +short @"$nameserver" A "$STATUS_HOST")
  for ip in "${authoritative_ips[@]}"; do
    if grep -Fxq "$ip" <<<"$target_ips" && \
      curl --fail --silent --show-error --resolve "${STATUS_HOST}:443:${ip}" "https://${STATUS_HOST}/healthz" >/dev/null && \
      links="$(curl --fail --silent --show-error --resolve "${STATUS_HOST}:443:${ip}" "https://${STATUS_HOST}/links")" && \
      jq -e --arg slug "$verification_slug" 'any(.[]; .slug == $slug)' >/dev/null <<<"$links"; then
      verified=true
      break 2
    fi
  done
  sleep 5
done
if [ "$verified" != true ]; then
  echo "error: authoritative DNS did not serve verified $target_region traffic within three minutes" >&2
  echo "       target ALB: $alb_dns" >&2
  exit 1
fi
log_event "traffic_verified_${TARGET}"
log_event "traffic_verified"
curl --fail --silent --show-error "https://${SENTRY_HOST}/healthz" >/dev/null
log_event "sentry_available_after_traffic_switch"
echo "Traffic verified on $TARGET through authoritative Route 53 DNS, workload health, and link $verification_slug. Sentry remained available."
