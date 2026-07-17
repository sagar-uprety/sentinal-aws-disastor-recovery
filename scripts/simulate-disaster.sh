#!/usr/bin/env bash
# Simulates a regional application failure by scaling prod ECS desired_count
# to 0. Does not alter traffic routing: the ALB keeps its listener and DNS
# unchanged, so requests continue arriving with zero healthy targets.
set -euo pipefail

PROD_REGION="eu-central-1"
CLUSTER="sentinel-aws-dr-prod"
SERVICE="sentinel-aws-dr-prod"
DRILL_LOG="${DRILL_LOG:-./drill-events.log}"

start_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "disaster_declared	${start_ts}" >>"$DRILL_LOG"

aws ecs update-service \
  --region "$PROD_REGION" \
  --cluster "$CLUSTER" \
  --service "$SERVICE" \
  --desired-count 0 \
  >/dev/null

echo "Primary desired_count set to 0 at ${start_ts}."
echo "Event logged to ${DRILL_LOG}. Run failover.sh to begin recovery."
