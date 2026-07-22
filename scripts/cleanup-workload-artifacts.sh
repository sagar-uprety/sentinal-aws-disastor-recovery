#!/usr/bin/env bash
set -euo pipefail

readonly PROJECT_NAME="${PROJECT_NAME:-sentinel-aws-dr}"
readonly PRIMARY_REGION="${PRIMARY_REGION:-eu-central-1}"
readonly DR_REGION="${DR_REGION:-eu-west-1}"
readonly ECR_REPOSITORY="${PROJECT_NAME}-prod"
readonly PROD_DATABASE="${PROJECT_NAME}-prod"
readonly DR_DATABASE="${PROJECT_NAME}-dr"
readonly SNAPSHOT_PREFIX="${DR_DATABASE}-pre-failback-"

if [[ "${CONFIRM_CLEANUP:-}" != "YES" ]]; then
  echo "Cleanup requires CONFIRM_CLEANUP=YES." >&2
  exit 1
fi

if aws ecr describe-repositories \
  --region "$DR_REGION" \
  --repository-names "$ECR_REPOSITORY" >/dev/null 2>&1; then
  aws ecr delete-repository \
    --region "$DR_REGION" \
    --repository-name "$ECR_REPOSITORY" \
    --force >/dev/null
fi

snapshot_ids="$(aws rds describe-db-snapshots \
  --region "$DR_REGION" \
  --snapshot-type manual \
  --query "DBSnapshots[?starts_with(DBSnapshotIdentifier, '$SNAPSHOT_PREFIX')].DBSnapshotIdentifier" \
  --output text)"
if [[ -n "$snapshot_ids" && "$snapshot_ids" != "None" ]]; then
  read -r -a snapshots <<<"$snapshot_ids"
  for snapshot_id in "${snapshots[@]}"; do
    aws rds delete-db-snapshot \
      --region "$DR_REGION" \
      --db-snapshot-identifier "$snapshot_id" >/dev/null
    aws rds wait db-snapshot-deleted \
      --region "$DR_REGION" \
      --db-snapshot-identifier "$snapshot_id"
  done
fi

backup_arns="$(aws rds describe-db-instance-automated-backups \
  --region "$DR_REGION" \
  --query "DBInstanceAutomatedBackups[?contains(['$PROD_DATABASE', '$DR_DATABASE'], DBInstanceIdentifier)].DBInstanceAutomatedBackupsArn" \
  --output text)"
if [[ -n "$backup_arns" && "$backup_arns" != "None" ]]; then
  read -r -a backups <<<"$backup_arns"
  for backup_arn in "${backups[@]}"; do
    aws rds delete-db-instance-automated-backup \
      --region "$DR_REGION" \
      --db-instance-automated-backups-arn "$backup_arn" >/dev/null
  done
fi

for _ in {1..60}; do
  remaining_backups="$(aws rds describe-db-instance-automated-backups \
    --region "$DR_REGION" \
    --query "length(DBInstanceAutomatedBackups[?contains(['$PROD_DATABASE', '$DR_DATABASE'], DBInstanceIdentifier)])" \
    --output text)"
  [ "$remaining_backups" = "0" ] && break
  sleep 5
done

log_groups=(
  "$PRIMARY_REGION:/aws/ecs/containerinsights/${PROJECT_NAME}-prod/performance"
  "$PRIMARY_REGION:/aws/rds/instance/${PROJECT_NAME}-prod/postgresql"
  "$DR_REGION:/aws/ecs/containerinsights/${PROJECT_NAME}-dr/performance"
  "$DR_REGION:/aws/rds/instance/${PROJECT_NAME}-dr/postgresql"
)
for regional_log_group in "${log_groups[@]}"; do
  region="${regional_log_group%%:*}"
  log_group_name="${regional_log_group#*:}"
  exists="$(aws logs describe-log-groups \
    --region "$region" \
    --log-group-name-prefix "$log_group_name" \
    --query "length(logGroups[?logGroupName == '$log_group_name'])" \
    --output text)"
  if [[ "$exists" != "0" ]]; then
    aws logs delete-log-group \
      --region "$region" \
      --log-group-name "$log_group_name"
  fi
  remaining_log_group="$(aws logs describe-log-groups \
    --region "$region" \
    --log-group-name-prefix "$log_group_name" \
    --query "length(logGroups[?logGroupName == '$log_group_name'])" \
    --output text)"
  if [[ "$remaining_log_group" != "0" ]]; then
    echo "Log group cleanup verification failed for $log_group_name." >&2
    exit 1
  fi
done

remaining_repository="$(aws ecr describe-repositories \
  --region "$DR_REGION" \
  --query "length(repositories[?repositoryName == '$ECR_REPOSITORY'])" \
  --output text)"
remaining_snapshots="$(aws rds describe-db-snapshots \
  --region "$DR_REGION" \
  --snapshot-type manual \
  --query "length(DBSnapshots[?starts_with(DBSnapshotIdentifier, '$SNAPSHOT_PREFIX')])" \
  --output text)"
remaining_backups="$(aws rds describe-db-instance-automated-backups \
  --region "$DR_REGION" \
  --query "length(DBInstanceAutomatedBackups[?contains(['$PROD_DATABASE', '$DR_DATABASE'], DBInstanceIdentifier)])" \
  --output text)"

if [[ "$remaining_repository" != "0" || "$remaining_snapshots" != "0" || "$remaining_backups" != "0" ]]; then
  echo "Workload artifact cleanup verification failed." >&2
  exit 1
fi

echo "Workload artifacts removed. Bootstrap resources were not targeted."
