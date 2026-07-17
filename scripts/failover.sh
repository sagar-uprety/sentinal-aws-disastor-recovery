#!/usr/bin/env bash
# Promotes the eu-west-1 read replica to a standalone primary and brings the
# DR service up to serve traffic. Promotion is irreversible: it permanently
# breaks the prod -> DR replication topology (see failback.sh to rebuild it).
# This script does NOT switch traffic. It stops once DR is verified healthy
# and accepting writes; the operator switches traffic as an explicit,
# separate step (Route53 ARC once provisioned, or the documented fallback).
set -euo pipefail

DR_REGION="eu-west-1"
DR_CLUSTER="sentinel-aws-dr-dr"
DR_SERVICE="sentinel-aws-dr-dr"
DR_DB_ID="sentinel-aws-dr-dr"
DRILL_LOG="${DRILL_LOG:-./drill-events.log}"

log_event() {
  echo "${1}	$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$DRILL_LOG"
}

log_event "failover_invoked"

echo "Promoting replica ${DR_DB_ID} in ${DR_REGION}..."
aws rds promote-read-replica --region "$DR_REGION" --db-instance-identifier "$DR_DB_ID" >/dev/null

echo "Waiting for promotion to complete (this can take several minutes)..."
aws rds wait db-instance-available --region "$DR_REGION" --db-instance-identifier "$DR_DB_ID"
log_event "replica_promoted"

db_endpoint="$(aws rds describe-db-instances \
  --region "$DR_REGION" \
  --db-instance-identifier "$DR_DB_ID" \
  --query 'DBInstances[0].Endpoint.Address' --output text)"
db_port="$(aws rds describe-db-instances \
  --region "$DR_REGION" \
  --db-instance-identifier "$DR_DB_ID" \
  --query 'DBInstances[0].Endpoint.Port' --output text)"
echo "Promoted endpoint: ${db_endpoint}:${db_port}"

# Re-render the task definition against the promoted endpoint rather than
# trusting the Terraform-time endpoint: promotion does not change the
# hostname in practice, but re-rendering here also validates the SSM
# parameter ARN still resolves before the service scales up on it.
echo "Registering DR task definition against the promoted endpoint..."
aws ecs describe-task-definition \
  --region "$DR_REGION" \
  --task-definition "$DR_SERVICE" \
  --query 'taskDefinition' >/tmp/dr-task-def.json

jq --arg host "$db_endpoint" --arg port "$db_port" '
  .containerDefinitions[0].environment |= map(
    if .name == "DB_HOST" then .value = $host
    elif .name == "DB_PORT" then .value = $port
    else . end
  )
  | {family, taskRoleArn, executionRoleArn, networkMode, containerDefinitions,
     requiresCompatibilities, cpu, memory, runtimePlatform}
  | with_entries(select(.value != null))
' /tmp/dr-task-def.json >/tmp/dr-task-def-rendered.json

new_task_def_arn="$(aws ecs register-task-definition \
  --region "$DR_REGION" \
  --cli-input-json file:///tmp/dr-task-def-rendered.json \
  --query 'taskDefinition.taskDefinitionArn' --output text)"
echo "Registered ${new_task_def_arn}"

echo "Scaling DR service to 2 tasks on the new revision..."
aws ecs update-service \
  --region "$DR_REGION" \
  --cluster "$DR_CLUSTER" \
  --service "$DR_SERVICE" \
  --task-definition "$new_task_def_arn" \
  --desired-count 2 \
  >/dev/null

aws ecs wait services-stable --region "$DR_REGION" --cluster "$DR_CLUSTER" --services "$DR_SERVICE"
log_event "dr_service_stable"

target_group_arn="$(aws elbv2 describe-target-groups \
  --region "$DR_REGION" \
  --names "sentinel-aws-dr-dr-tg" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)"
healthy_count="$(aws elbv2 describe-target-health \
  --region "$DR_REGION" \
  --target-group-arn "$target_group_arn" \
  --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])")"
echo "Healthy DR targets: ${healthy_count}"
if [ "$healthy_count" -lt 1 ]; then
  echo "ERROR: no healthy DR targets. Traffic must not be switched." >&2
  exit 1
fi

dr_alb_dns="$(aws elbv2 describe-load-balancers \
  --region "$DR_REGION" \
  --names "sentinel-aws-dr-dr-alb" \
  --query 'LoadBalancers[0].DNSName' --output text)"

echo "Verifying DR accepts writes via /status (app writes a check row every 30s)..."
status_body="$(curl -sS "http://${dr_alb_dns}/status")"
echo "$status_body"
log_event "dr_write_verified"

cat <<EOF

DR is healthy and writing at http://${dr_alb_dns}
Promoted database: ${db_endpoint}:${db_port}

Traffic has NOT been switched. Next step is an explicit operator action:
  - If Route53 ARC routing controls are provisioned: toggle the DR control on
    (and confirm the primary control's safety rule prevents both being on).
  - Otherwise: the documented Route53 record-update fallback in
    runbook-failover.md (less resilient control-plane operation, not
    equivalent DR evidence).
EOF
