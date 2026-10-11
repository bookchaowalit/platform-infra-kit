#!/usr/bin/env bash
# Safe apply wrapper for Hetzner staging (fsn1).
# Does NOT run apply unless every gate passes and the operator confirms.
#
# Required env:
#   PREFLIGHT_PROVISION=1
#   SOLO_EMPIRE_APPLY_CONFIRM=yes
#   ALLOW_SSH_CIDRS=...
#   SSH_KEY_IDS=...
#   HCLOUD_TOKEN=... (from secret manager)
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (state backend)
#
# Required files:
#   envs/staging/fsn1/backend.hcl  (encrypt=true, use_lockfile=true)
#   Reviewed plan: /tmp/solo-staging-fsn1-provision.tfplan (or PLAN_FILE=)
#
# Usage:
#   # 1) create and review plan (no apply)
#   bash apply-staging.sh plan
#   # 2) after human review:
#   PREFLIGHT_PROVISION=1 SOLO_EMPIRE_APPLY_CONFIRM=yes bash apply-staging.sh apply
#
set -euo pipefail
export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/envs/staging/fsn1"
ACTION="${1:-}"
PLAN_FILE="${PLAN_FILE:-/tmp/solo-staging-fsn1-provision.tfplan}"

die() { echo "ERROR: $*" >&2; exit 1; }

cd "$DIR"

if [[ "$ACTION" != "plan" && "$ACTION" != "apply" ]]; then
  cat <<EOF
Usage:
  bash apply-staging.sh plan    # provision=true plan to remote state (no apply)
  bash apply-staging.sh apply   # apply ONLY after gates + confirmation

Never use this for production. Never commit secrets.
EOF
  exit 2
fi

echo "==> Gate: PREFLIGHT_PROVISION=1"
[[ "${PREFLIGHT_PROVISION:-0}" == "1" ]] || die "Set PREFLIGHT_PROVISION=1"

echo "==> Gate: preflight-staging.sh"
bash "$ROOT/scripts/preflight-staging.sh"

echo "==> Gate: backend.tf + backend.hcl remote encrypted + lock"
[[ -f "$DIR/backend.tf" ]] || die "Missing backend.tf — copy backend.tf.example"
grep -q 'backend "s3"' "$DIR/backend.tf" || die "backend.tf must declare backend \"s3\""
BACKEND_HCL="${BACKEND_HCL:-$DIR/backend.hcl}"
[[ -f "$BACKEND_HCL" ]] || die "Missing $BACKEND_HCL — copy backend.hcl.example"
grep -qiE 'encrypt[[:space:]]*=[[:space:]]*true' "$BACKEND_HCL" || die "encrypt=true required"
grep -qiE 'use_lockfile[[:space:]]*=[[:space:]]*true' "$BACKEND_HCL" \
  || grep -qiE 'dynamodb_table[[:space:]]*=' "$BACKEND_HCL" \
  || die "state locking required"
[[ ! -f "$DIR/terraform.tfstate" ]] || die "Local terraform.tfstate must not exist for provision apply"

# Build -var args from env (no secrets written to disk by this script)
VAR_ARGS=(-var='provision=true')
if [[ -n "${ALLOW_SSH_CIDRS:-}" ]]; then
  # HCL list: ["a","b"]
  IFS=',' read -r -a _cidrs <<<"$ALLOW_SSH_CIDRS"
  _list="["
  for i in "${!_cidrs[@]}"; do
    [[ $i -gt 0 ]] && _list+=","
    _list+="\"${_cidrs[$i]}\""
  done
  _list+="]"
  VAR_ARGS+=(-var="allow_ssh_cidrs=${_list}")
fi
if [[ -n "${SSH_KEY_IDS:-}" ]]; then
  IFS=',' read -r -a _keys <<<"$SSH_KEY_IDS"
  _list="["
  for i in "${!_keys[@]}"; do
    [[ $i -gt 0 ]] && _list+=","
    _list+="\"${_keys[$i]}\""
  done
  _list+="]"
  VAR_ARGS+=(-var="ssh_key_ids=${_list}")
fi

echo "==> tofu init (remote backend)"
tofu init -input=false -backend-config="$BACKEND_HCL"

if [[ "$ACTION" == "plan" ]]; then
  echo "==> tofu plan provision=true → $PLAN_FILE (no apply)"
  [[ -n "${HCLOUD_TOKEN:-}" ]] || die "HCLOUD_TOKEN required for provision plan"
  tofu plan -input=false "${VAR_ARGS[@]}" -out="$PLAN_FILE"
  echo "Review the plan carefully. Sensitive values should appear as (sensitive)."
  echo "After review, re-run with: PREFLIGHT_PROVISION=1 SOLO_EMPIRE_APPLY_CONFIRM=yes $0 apply"
  exit 0
fi

# apply path
echo "==> Gate: SOLO_EMPIRE_APPLY_CONFIRM=yes"
[[ "${SOLO_EMPIRE_APPLY_CONFIRM:-}" == "yes" ]] || die "Set SOLO_EMPIRE_APPLY_CONFIRM=yes after human review"

echo "==> Gate: reviewed plan file exists: $PLAN_FILE"
[[ -f "$PLAN_FILE" ]] || die "Missing plan file. Run: $0 plan first and review it."

echo "==> Gate: plan must target provision=true (heuristic)"
if command -v tofu >/dev/null; then
  # Show non-sensitive summary only
  tofu show -no-color "$PLAN_FILE" | head -n 40 || true
fi

echo ""
echo "About to: tofu apply \"$PLAN_FILE\""
echo "This will create Hetzner resources and write secrets into REMOTE encrypted state."
if [[ -t 0 ]]; then
  read -r -p "Type APPLY-STAGING-FSN1 to continue: " CONFIRM
  [[ "$CONFIRM" == "APPLY-STAGING-FSN1" ]] || die "Confirmation string mismatch; aborting"
else
  [[ "${SOLO_EMPIRE_APPLY_TTY_BYPASS:-}" == "1" ]] || die "Non-interactive apply requires SOLO_EMPIRE_APPLY_TTY_BYPASS=1 in addition to SOLO_EMPIRE_APPLY_CONFIRM=yes"
fi

echo "==> tofu apply (approved plan only)"
tofu apply -input=false "$PLAN_FILE"
echo "Apply finished. Rotate any credentials that appeared in break-glass logs. Do not commit state."
