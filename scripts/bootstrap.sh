#!/usr/bin/env bash
# plans and applies bootstrap resources that CI needs before any workflow can run.
# run manually because CI depends on these resources.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
ROOT="$(cd "$SCRIPT_DIR/../terraform/environments/bootstrap" && pwd)"
readonly ROOT
readonly PLAN_FILE="${BOOTSTRAP_PLAN_FILE:-$ROOT/bootstrap.tfplan}"
readonly OPERATION="${1:-}"

case "$OPERATION" in
plan)
  # saves a reviewable plan so apply cannot recalculate different changes.
  terraform -chdir="$ROOT" init -input=false
  terraform -chdir="$ROOT" plan -lock=false -input=false -out="$PLAN_FILE"
  terraform -chdir="$ROOT" show -no-color "$PLAN_FILE"
  echo "Bootstrap plan saved to $PLAN_FILE. Review it before requesting apply approval."
  ;;
apply)
  # requires both explicit approval and the previously reviewed plan artifact.
  if [ "${CONFIRM_BOOTSTRAP:-}" != "APPLY_BOOTSTRAP" ]; then
    echo "error: bootstrap apply requires CONFIRM_BOOTSTRAP=APPLY_BOOTSTRAP" >&2
    exit 1
  fi
  if [ ! -f "$PLAN_FILE" ]; then
    echo "error: no reviewed bootstrap plan exists at $PLAN_FILE; run '$0 plan' first" >&2
    exit 1
  fi
  terraform -chdir="$ROOT" show -no-color "$PLAN_FILE"
  terraform -chdir="$ROOT" apply -input=false -lock-timeout=5m "$PLAN_FILE"
  rm -f "$PLAN_FILE"
  ;;
*)
  echo "usage: $0 plan|apply" >&2
  exit 1
  ;;
esac
