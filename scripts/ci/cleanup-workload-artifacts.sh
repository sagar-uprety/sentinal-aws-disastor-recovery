#!/usr/bin/env bash
# removes workload artifacts that remain after Terraform destroy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=../config.sh
source "$SCRIPT_DIR/../config.sh"

readonly PROD_ECR_REPOSITORY="$PROD_RESOURCE_NAME"
readonly PROD_DATABASE="$PROD_RESOURCE_NAME"
readonly DR_DATABASE="$DR_RESOURCE_NAME"
readonly SNAPSHOT_PREFIX="${DR_DATABASE}-pre-failback-"

if [[ "${CONFIRM_CLEANUP:-}" != "YES" ]]; then
  echo "error: cleanup requires CONFIRM_CLEANUP=YES" >&2
  exit 1
fi

# uses adaptive retries because ECS throttles rapid task-definition mutations.
export AWS_RETRY_MODE="adaptive"
export AWS_MAX_ATTEMPTS="10"

# verifies Terraform removed the source repository before cleaning its replicated copy.
primary_repository_count="$(aws ecr describe-repositories \
  --region "$PRIMARY_REGION" \
  --query "length(repositories[?repositoryName == '$PROD_ECR_REPOSITORY'])" \
  --output text)"
if [[ "$primary_repository_count" != "0" ]]; then
  echo "error: ECR repository still present in $PRIMARY_REGION: $PROD_ECR_REPOSITORY" >&2
  exit 1
fi

# removes the AWS-created destination repository that Terraform does not own.
replicated_repository_count="$(aws ecr describe-repositories \
  --region "$DR_REGION" \
  --query "length(repositories[?repositoryName == '$PROD_ECR_REPOSITORY'])" \
  --output text)"
if [[ "$replicated_repository_count" != "0" ]]; then
  aws ecr delete-repository \
    --region "$DR_REGION" \
    --repository-name "$PROD_ECR_REPOSITORY" \
    --force >/dev/null
fi

# removes temporary rollback snapshots created during completed failback drills.
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

# verifies Terraform removed automated backups instead of masking a failed destroy.
for region in "$PRIMARY_REGION" "$DR_REGION"; do
  backup_count="$(aws rds describe-db-instance-automated-backups \
    --region "$region" \
    --query "length(DBInstanceAutomatedBackups[?contains(['$PROD_DATABASE', '$DR_DATABASE'], DBInstanceIdentifier)])" \
    --output text)"
  if [[ "$backup_count" != "0" ]]; then
    echo "error: automated backups still present in $region" >&2
    exit 1
  fi
done

# purges untracked task-definition revisions left by earlier deploys.
for region in "$PRIMARY_REGION" "$DR_REGION"; do
  families="$(aws ecs list-task-definition-families \
    --region "$region" \
    --family-prefix "$PROJECT_NAME" \
    --status ALL \
    --query "families" \
    --output text)"
  [[ -z "$families" || "$families" == "None" ]] && continue
  read -r -a family_list <<<"$families"
  for family in "${family_list[@]}"; do
    revision_arns="$(aws ecs list-task-definitions \
      --region "$region" \
      --family-prefix "$family" \
      --status ACTIVE \
      --query "taskDefinitionArns" \
      --output text) $(aws ecs list-task-definitions \
      --region "$region" \
      --family-prefix "$family" \
      --status INACTIVE \
      --query "taskDefinitionArns" \
      --output text)"
    revision_arns="${revision_arns//None/}"
    [[ -z "${revision_arns// /}" ]] && continue
    read -r -a revisions <<<"$revision_arns"
    for revision_arn in "${revisions[@]}"; do
      aws ecs deregister-task-definition \
        --region "$region" \
        --task-definition "$revision_arn" >/dev/null
      sleep 0.2
    done
    for ((i = 0; i < ${#revisions[@]}; i += 10)); do
      aws ecs delete-task-definitions \
        --region "$region" \
        --task-definitions "${revisions[@]:i:10}" >/dev/null
    done
  done
done

# verifies task-definition deletion removed every active and inactive revision.
remaining_task_definitions=0
for region in "$PRIMARY_REGION" "$DR_REGION"; do
  for status in ACTIVE INACTIVE; do
    count="$(aws ecs list-task-definitions \
      --region "$region" \
      --family-prefix "$PROJECT_NAME" \
      --status "$status" \
      --query "length(taskDefinitionArns)" \
      --output text)"
    remaining_task_definitions=$((remaining_task_definitions + count))
  done
done
if [[ "$remaining_task_definitions" != "0" ]]; then
  echo "error: task-definition cleanup verification failed" >&2
  exit 1
fi

# discovers service-created log groups by project prefix because Terraform does not own them.
log_group_prefixes=(
  "$PRIMARY_REGION:/aws/ecs/containerinsights/${PROJECT_NAME}-"
  "$PRIMARY_REGION:/aws/rds/instance/${PROJECT_NAME}-"
  "$DR_REGION:/aws/ecs/containerinsights/${PROJECT_NAME}-"
  "$DR_REGION:/aws/rds/instance/${PROJECT_NAME}-"
)
for regional_prefix in "${log_group_prefixes[@]}"; do
  region="${regional_prefix%%:*}"
  prefix="${regional_prefix#*:}"
  names="$(aws logs describe-log-groups \
    --region "$region" \
    --log-group-name-prefix "$prefix" \
    --query "logGroups[].logGroupName" \
    --output text)"
  [[ -z "$names" || "$names" == "None" ]] && continue
  read -r -a group_names <<<"$names"
  for name in "${group_names[@]}"; do
    aws logs delete-log-group --region "$region" --log-group-name "$name"
  done
done

# removes account-wide RDSOSMetrics groups only because this demo account has no other RDS workloads.
for region in "$PRIMARY_REGION" "$DR_REGION"; do
  exists="$(aws logs describe-log-groups \
    --region "$region" \
    --log-group-name-prefix "RDSOSMetrics" \
    --query "length(logGroups[?logGroupName == 'RDSOSMetrics'])" \
    --output text)"
  if [[ "$exists" != "0" ]]; then
    aws logs delete-log-group --region "$region" --log-group-name "RDSOSMetrics"
  fi
done

# verifies all discovered service-created log groups are gone.
remaining_log_groups=0
for region in "$PRIMARY_REGION" "$DR_REGION"; do
  for prefix in "/aws/ecs/containerinsights/${PROJECT_NAME}-" "/aws/rds/instance/${PROJECT_NAME}-" "RDSOSMetrics"; do
    count="$(aws logs describe-log-groups \
      --region "$region" \
      --log-group-name-prefix "$prefix" \
      --query "length(logGroups)" \
      --output text)"
    remaining_log_groups=$((remaining_log_groups + count))
  done
done
if [[ "$remaining_log_groups" != "0" ]]; then
  echo "error: log-group cleanup verification failed" >&2
  exit 1
fi

# verifies the replicated ECR repository was removed synchronously.
remaining_replicated_repository="$(aws ecr describe-repositories \
  --region "$DR_REGION" \
  --query "length(repositories[?repositoryName == '$PROD_ECR_REPOSITORY'])" \
  --output text)"
if [[ "$remaining_replicated_repository" != "0" ]]; then
  echo "error: replicated ECR repository cleanup verification failed" >&2
  exit 1
fi

# performs a final snapshot check after asynchronous RDS deletion waiters complete.
remaining_snapshots="$(aws rds describe-db-snapshots \
  --region "$DR_REGION" \
  --snapshot-type manual \
  --query "length(DBSnapshots[?starts_with(DBSnapshotIdentifier, '$SNAPSHOT_PREFIX')])" \
  --output text)"

if [[ "$remaining_snapshots" != "0" ]]; then
  echo "error: workload artifact cleanup verification failed" >&2
  exit 1
fi

echo "Workload artifacts removed. Bootstrap resources were not targeted."
