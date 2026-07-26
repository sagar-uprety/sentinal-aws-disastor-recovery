#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../terraform/environments/bootstrap" && pwd)"
PLAN_FILE="${BOOTSTRAP_PLAN_FILE:-$ROOT/bootstrap.tfplan}"
OPERATION="${1:-}"

case "$OPERATION" in
plan)
  terraform -chdir="$ROOT" init -input=false
  terraform -chdir="$ROOT" plan -lock=false -input=false -out="$PLAN_FILE"
  terraform -chdir="$ROOT" show -no-color "$PLAN_FILE"
  echo "Bootstrap plan saved to $PLAN_FILE. Review it before requesting apply approval."
  ;;
apply)
  if [ "${CONFIRM_BOOTSTRAP:-}" != "APPLY_BOOTSTRAP" ]; then
    echo "Bootstrap apply requires CONFIRM_BOOTSTRAP=APPLY_BOOTSTRAP." >&2
    exit 1
  fi
  if [ ! -f "$PLAN_FILE" ]; then
    echo "No reviewed bootstrap plan exists at $PLAN_FILE. Run '$0 plan' first." >&2
    exit 1
  fi
  terraform -chdir="$ROOT" show -no-color "$PLAN_FILE"
  terraform -chdir="$ROOT" apply -input=false -lock-timeout=5m "$PLAN_FILE"
  rm -f "$PLAN_FILE"
  ;;
*)
  echo "Usage: $0 plan|apply" >&2
  exit 1
  ;;
esac
