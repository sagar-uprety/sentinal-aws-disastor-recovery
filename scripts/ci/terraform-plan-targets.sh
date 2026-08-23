#!/usr/bin/env bash
# Maps changed Terraform paths to the root modules that import them.
set -euo pipefail

# Roots this workflow can plan; bootstrap is deliberately excluded (see below).
roots=(monitoring primary secondary)
monitoring=false
primary=false
secondary=false

mark() {
  case "$1" in
    monitoring) monitoring=true ;;
    primary) primary=true ;;
    secondary) secondary=true ;;
  esac
}

for path in "$@"; do
  case "$path" in
    terraform/environments/*/*)
      # A root's own path always maps to itself.
      root="${path#terraform/environments/}"
      mark "${root%%/*}"
      ;;
    terraform/modules/*/*)
      # A shared module maps to whichever roots actually declare it as a source, read straight
      # from each root's main.tf instead of hand-maintaining a duplicate module->root table here.
      module="${path#terraform/modules/}"
      module="${module%%/*}"
      for root in "${roots[@]}"; do
        if grep -qE "source[[:space:]]*=[[:space:]]*\"\.\./\.\./modules/${module}\"" \
          "terraform/environments/${root}/main.tf" 2>/dev/null; then
          mark "$root"
        fi
      done
      ;;
    # terraform-ci-iam/bootstrap fall through on purpose: bootstrap creates this workflow's own CI role, so it can't be planned through this workflow, and is covered separately by infrastructure-quality.yml.
  esac
done

# builds a JSON array of the roots that need to be planned, e.g. ["monitoring","primary"]
json=""
$monitoring && json='"monitoring"'
$primary && json+="${json:+,}\"primary\""
$secondary && json+="${json:+,}\"secondary\""
printf '[%s]\n' "$json"
