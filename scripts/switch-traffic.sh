#!/usr/bin/env bash
# Atomically switches pre-provisioned ARC controls and verifies authoritative DNS traffic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/drill-lib.sh"

ARC_CONTROL_REGION="${ARC_CONTROL_REGION:-us-west-2}"
ARC_CLUSTER_NAME="${ARC_CLUSTER_NAME:-sentinel-aws-dr-arc}"
ARC_CONTROL_PANEL_NAME="${ARC_CONTROL_PANEL_NAME:-sentinel-aws-dr-arc}"
STATUS_HOST="sentinel.sagaruprety.com.np"
HOSTED_ZONE_NAME="sentinel.sagaruprety.com.np."
TARGET="${1:-}"

case "$TARGET" in
dr)
  [ "${CONFIRM_TRAFFIC_SWITCH:-}" = "DR" ] || {
    echo "Set CONFIRM_TRAFFIC_SWITCH=DR to route traffic to DR." >&2
    exit 1
  }
  require_current_event "dr_targets_healthy"
  require_current_event "dr_write_verified"
  require_current_event "dr_pre_outage_last_check"
  expected_primary="On"
  expected_dr="Off"
  new_primary="Off"
  new_dr="On"
  target_region="eu-west-1"
  target_alb="sentinel-aws-dr-dr-alb"
  ;;
primary)
  [ "${CONFIRM_TRAFFIC_SWITCH:-}" = "PRIMARY" ] || {
    echo "Set CONFIRM_TRAFFIC_SWITCH=PRIMARY after failback verification." >&2
    exit 1
  }
  require_current_event "failback_ready"
  expected_primary="Off"
  expected_dr="On"
  new_primary="On"
  new_dr="Off"
  target_region="eu-central-1"
  target_alb="sentinel-aws-dr-prod-alb"
  ;;
*)
  echo "Usage: $0 {dr|primary}" >&2
  exit 1
  ;;
esac

cluster_json="$(aws route53-recovery-control-config list-clusters \
  --region "$ARC_CONTROL_REGION" \
  --query "Clusters[?Name=='${ARC_CLUSTER_NAME}'] | [0]" --output json)"
cluster_arn="$(jq -r '.ClusterArn // empty' <<<"$cluster_json")"
if [ -z "$cluster_arn" ]; then
  echo "ERROR: ARC cluster $ARC_CLUSTER_NAME was not found." >&2
  exit 1
fi

control_panel_arn="$(aws route53-recovery-control-config list-control-panels \
  --region "$ARC_CONTROL_REGION" \
  --cluster-arn "$cluster_arn" \
  --query "ControlPanels[?Name=='${ARC_CONTROL_PANEL_NAME}'].ControlPanelArn | [0]" --output text)"
if [ -z "$control_panel_arn" ] || [ "$control_panel_arn" = "None" ]; then
  echo "ERROR: ARC control panel $ARC_CONTROL_PANEL_NAME was not found." >&2
  exit 1
fi

routing_controls="$(aws route53-recovery-control-config list-routing-controls \
  --region "$ARC_CONTROL_REGION" \
  --control-panel-arn "$control_panel_arn" --output json)"
primary_control_arn="$(jq -r '.RoutingControls[] | select(.Name == "primary") | .RoutingControlArn' <<<"$routing_controls")"
dr_control_arn="$(jq -r '.RoutingControls[] | select(.Name == "dr") | .RoutingControlArn' <<<"$routing_controls")"
if [ -z "$primary_control_arn" ] || [ -z "$dr_control_arn" ]; then
  echo "ERROR: primary and DR routing controls were not found." >&2
  exit 1
fi

arc_endpoints=()
while IFS= read -r entry; do
  arc_endpoints[${#arc_endpoints[@]}]="$entry"
done < <(jq -r '.ClusterEndpoints[] | [.Endpoint, .Region] | @tsv' <<<"$cluster_json")
if [ "${#arc_endpoints[@]}" -eq 0 ]; then
  echo "ERROR: ARC cluster has no data-plane endpoints." >&2
  exit 1
fi

arc_get_state() {
  local control_arn="$1" endpoint region state
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

primary_state="$(arc_get_state "$primary_control_arn")"
dr_state="$(arc_get_state "$dr_control_arn")"
if [ "$primary_state" != "$expected_primary" ] || [ "$dr_state" != "$expected_dr" ]; then
  echo "ERROR: unexpected ARC state primary=$primary_state dr=$dr_state; expected primary=$expected_primary dr=$expected_dr." >&2
  exit 1
fi

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
  echo "ERROR: all ARC data-plane endpoints rejected the atomic switch." >&2
  exit 1
fi
log_event "traffic_switch_requested"

primary_state="$(arc_get_state "$primary_control_arn")"
dr_state="$(arc_get_state "$dr_control_arn")"
if [ "$primary_state" != "$new_primary" ] || [ "$dr_state" != "$new_dr" ]; then
  echo "ERROR: ARC did not reach requested state primary=$new_primary dr=$new_dr." >&2
  exit 1
fi
log_event "traffic_switched"

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

verified=false
for _ in {1..36}; do
  authoritative_ips=()
  while IFS= read -r ip; do
    authoritative_ips[${#authoritative_ips[@]}]="$ip"
  done < <(dig +short @"$nameserver" A "$STATUS_HOST")
  for ip in "${authoritative_ips[@]}"; do
    topology="$(curl -fsS --resolve "${STATUS_HOST}:443:${ip}" "https://${STATUS_HOST}/topology" || true)"
    if jq -e --arg region "$target_region" '.application.region == $region and .database.available == true' >/dev/null <<<"$topology"; then
      verified=true
      break 2
    fi
  done
  sleep 5
done
if [ "$verified" != true ]; then
  echo "ERROR: authoritative DNS did not serve verified $target_region application traffic within three minutes." >&2
  echo "Target ALB: $alb_dns" >&2
  exit 1
fi
log_event "traffic_verified_${TARGET}"
log_event "traffic_verified"
echo "Traffic verified on $TARGET through authoritative Route 53 DNS and /topology."
if [ "$TARGET" = "PRIMARY" ]; then
  cat <<'EOF'
Dispatch the protected topology-reset workflow and follow both plan/apply job logs:
  gh workflow run recovery.yml --ref main -f operation=failback-reset -f confirm_failback=RESET_DR
EOF
fi
