#!/usr/bin/env bash
# Safe plan-only helper for single-region staging.
# Never runs apply. provision defaults to false.
set -euo pipefail

export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/envs/staging/fsn1"

cd "$DIR"

if [[ "${1:-}" == "apply" ]]; then
  echo "Refusing apply from plan-staging.sh. Use explicit human-approved process." >&2
  exit 2
fi

echo "==> preflight (structural)"
bash "$ROOT/scripts/preflight-staging.sh"

echo "==> tofu fmt"
tofu fmt -recursive "$ROOT/modules" "$DIR"

echo "==> tofu init (local scaffold; provision=false only)"
# Local state is allowed ONLY for provision=false scaffold.
# provision=true must use: apply-staging.sh (backend.tf + backend.hcl remote).
# Temporarily hide backend.tf if present so scaffold stays local.
_backend_tf_moved=0
if [[ -f backend.tf ]]; then
  mv backend.tf backend.tf.provision-hidden
  _backend_tf_moved=1
fi
rm -f .terraform/terraform.tfstate
tofu init -input=false -reconfigure

echo "==> tofu validate"
tofu validate

echo "==> tofu plan (provision=false)"
# Dummy token is fine when no resources are created.
export HCLOUD_TOKEN="${HCLOUD_TOKEN:-0000000000000000000000000000000000000000000000000000000000000000}"
tofu plan -input=false -var='provision=false' -out=/tmp/solo-staging-fsn1.tfplan
_plan_rc=$?

if [[ "$_backend_tf_moved" -eq 1 ]]; then
  mv backend.tf.provision-hidden backend.tf
fi
[[ "$_plan_rc" -eq 0 ]] || exit "$_plan_rc"

echo "Plan written to /tmp/solo-staging-fsn1.tfplan (not applied)."
echo "To inspect: tofu show /tmp/solo-staging-fsn1.tfplan"
echo "For provision=true: cp backend.tf.example backend.tf && scripts/apply-staging.sh plan"
