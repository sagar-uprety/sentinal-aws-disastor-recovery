#!/usr/bin/env bash
# switches pre-provisioned ARC controls and verifies authoritative DNS traffic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=../config.sh
source "$SCRIPT_DIR/../config.sh"
# shellcheck source=drill-lib.sh
source "$SCRIPT_DIR/drill-lib.sh"

readonly ARC_CONTROL_REGION="${ARC_CONTROL_REGION:-us-west-2}"
readonly ARC_CLUSTER_NAME="${ARC_CLUSTER_NAME:-${PROJECT_NAME}-arc}"
readonly ARC_CONTROL_PANEL_NAME="${ARC_CONTROL_PANEL_NAME:-${PROJECT_NAME}-arc}"
readonly STATUS_HOST="$WORKLOAD_HOST"
readonly HOSTED_ZONE_NAME="${BASE_DOMAIN}."
readonly TARGET="${1:-}"

case "$TARGET" in
initialize)
  # establishes the resting primary-on state before the first drill.
  [ "${CONFIRM_TRAFFIC_SWITCH:-}" = "INITIALIZE" ] || {
    echo "error: set CONFIRM_TRAFFIC_SWITCH=INITIALIZE before preparing ARC controls" >&2
    exit 1
  }
  initialize=true
  new_primary="On"
  new_dr="Off"
  ;;
dr)
  # requires healthy, writable DR before moving public traffic away from prod.
  [ "${CONFIRM_TRAFFIC_SWITCH:-}" = "DR" ] || {
    echo "error: set CONFIRM_TRAFFIC_SWITCH=DR to route traffic to DR" >&2
    exit 1
  }
  require_current_event "dr_targets_healthy"
  require_current_event "dr_write_verified"
  require_current_event "pre_outage_link_slug"
  expected_primary="On"
  expected_dr="Off"
  new_primary="Off"
  new_dr="On"
  target_region="$DR_REGION"
  target_alb="${DR_RESOURCE_NAME}-alb"
  verification_slug="$(current_event_ts pre_outage_link_slug)"
  initialize=false
  ;;
primary)
  # requires completed failback verification before returning traffic to prod.
  [ "${CONFIRM_TRAFFIC_SWITCH:-}" = "PRIMARY" ] || {
    echo "error: set CONFIRM_TRAFFIC_SWITCH=PRIMARY after failback verification" >&2
    exit 1
  }
  require_current_event "failback_ready"
  expected_primary="Off"
  expected_dr="On"
  new_primary="On"
  new_dr="Off"
  target_region="$PRIMARY_REGION"
  target_alb="${PROD_RESOURCE_NAME}-alb"
  verification_slug="$(current_event_ts failback_dr_final_link_slug)"
  initialize=false
  ;;
*)
  echo "usage: $0 {initialize|dr|primary}" >&2
  exit 1
  ;;
esac

# resolves ARC names into data-plane routing-control ARNs.
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
dr_control_arn="$(jq -r '.RoutingControls[] | select(.Name == "dr") | .RoutingControlArn' <<<"$routing_controls")"
if [ -z "$primary_control_arn" ] || [ -z "$dr_control_arn" ]; then
  echo "error: primary and DR routing controls were not found" >&2
  exit 1
fi

# collects every ARC endpoint so control operations survive one unavailable region.
arc_endpoints=()
while IFS= read -r entry; do
  arc_endpoints[${#arc_endpoints[@]}]="$entry"
done < <(jq -r '.ClusterEndpoints[] | [.Endpoint, .Region] | @tsv' <<<"$cluster_json")
if [ "${#arc_endpoints[@]}" -eq 0 ]; then
  echo "error: ARC cluster has no data-plane endpoints" >&2
  exit 1
fi

# reads routing state through the first available regional endpoint.
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

# rejects stale or partially completed switches before changing routing state.
primary_state="$(arc_get_state "$primary_control_arn")"
dr_state="$(arc_get_state "$dr_control_arn")"
if [ "$initialize" != true ] && { [ "$primary_state" != "$expected_primary" ] || [ "$dr_state" != "$expected_dr" ]; }; then
  echo "error: ARC state is primary=$primary_state dr=$dr_state; expected $expected_primary/$expected_dr" >&2
  exit 1
fi

# updates both controls atomically through the first available endpoint.
switch_succeeded=false
for entry in "${arc_endpoints[@]}"; do
  IFS=$'\t' read -r endpoint region <<<"$entry"
  if aws route53-recovery-cluster \
    --endpoint-url "$endpoint" \
    --region "$region" \
    update-routing-control-states \
    --update-routing-control-state-entries \
      "RoutingControlArn=$primary_control_arn,RoutingControlState=$new_primary" \
      "RoutingControlArn=$dr_control_arn,RoutingControlState=$new_dr" \
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

# confirms ARC reached requested state instead of trusting request acceptance.
primary_state="$(arc_get_state "$primary_control_arn")"
dr_state="$(arc_get_state "$dr_control_arn")"
if [ "$primary_state" != "$new_primary" ] || [ "$dr_state" != "$new_dr" ]; then
  echo "error: ARC did not reach requested state primary=$new_primary dr=$new_dr" >&2
  exit 1
fi
log_event "traffic_switched"

if [ "$initialize" = true ]; then
  log_event "arc_initialized"
  echo "ARC initialized: primary=On dr=Off."
  exit 0
fi

# bypasses resolver caches by querying an authoritative Route 53 nameserver.
zone_id="$(aws route53 list-hosted-zones-by-name \
  --dns-name "$HOSTED_ZONE_NAME" \
  --query "HostedZones[?Name=='${HOSTED_ZONE_NAME}'].Id | [0]" --output text)"
nameserver="$(aws route53 get-hosted-zone \
  --id "$zone_id" \
  --query 'DelegationSet.NameServers[0]' --output text)"
alb_dns="$(aws elbv2 describe-load-balancers \
  --region "$target_region" \
  --names "$target_alb" \
  --query 'LoadBalancers[0].DNSName' --output text)"

# verifies authoritative DNS, target health, and expected data before declaring cutover complete.
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
curl --fail --silent --show-error "https://${MONITOR_HOST}/healthz" >/dev/null
log_event "monitor_available_after_traffic_switch"
echo "Traffic verified on $TARGET through authoritative Route 53 DNS, workload health, and link $verification_slug. Monitor remained available."
if [ "$TARGET" = "primary" ]; then
  cat <<'EOF'
Dispatch the protected topology-reset workflow and follow both plan/apply job logs:
  gh workflow run recovery.yml --ref main -f operation=failback-reset -f confirm_failback=RESET_DR
EOF
fi
