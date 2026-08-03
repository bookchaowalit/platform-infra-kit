#!/usr/bin/env bash
# Preflight checks for Hetzner staging IaC (never applies).
#
# Always (structural):
#   - provision defaults to false
#   - production module root absent
#   - registry TLS design present
#   - firewall forbids public 5000
#   - remote state design present (encrypt + lockfile examples)
#   - bootstrap state key separate from staging
#
# When PREFLIGHT_PROVISION=1 (apply readiness):
#   - non-empty ALLOW_SSH_CIDRS / SSH_KEY_IDS
#   - forbidden 0.0.0.0/0 and ::/0
#   - reject local terraform.tfstate for provision path
#   - require backend.hcl with encrypt + use_lockfile
#   - reject unencrypted / unlocked backend config
#
set -euo pipefail
export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGING="$ROOT/envs/staging/fsn1"
BOOTSTRAP="$ROOT/envs/bootstrap/fsn1"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  ✅ $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $*"; }

echo "=== Staging preflight (no apply) ==="

# provision defaults to false
if awk '/variable "provision"/,/^}/' "$STAGING/variables.tf" | grep -q 'default[[:space:]]*=[[:space:]]*false'; then
  ok "provision defaults to false"
else
  fail "provision default is not false"
fi

# production absent
if [[ ! -f "$ROOT/envs/production/main.tf" ]] && [[ ! -f "$ROOT/envs/production/versions.tf" ]]; then
  ok "production module/root remains absent"
else
  fail "production OpenTofu root exists (must stay disabled)"
fi
if grep -qi DISABLED "$ROOT/envs/production/README.md" 2>/dev/null; then
  ok "production README marked DISABLED"
else
  fail "production README missing DISABLED marker"
fi

# forbidden world-open SSH patterns in network module for port 22
if grep -A12 'port.*=.*"22"' "$ROOT/modules/network/main.tf" | grep -qE '0\.0\.0\.0/0|::/0'; then
  fail "SSH firewall rule appears to allow world-open CIDRs"
else
  ok "SSH rules do not hardcode 0.0.0.0/0 or ::/0"
fi

# registry TLS configuration present
if grep -q 'tls_self_signed_cert' "$ROOT/modules/registry/main.tf" \
  && grep -q 'tls_locally_signed_cert' "$ROOT/modules/registry/main.tf" \
  && grep -q 'dns_names' "$ROOT/modules/registry/main.tf" \
  && grep -q 'ip_addresses' "$ROOT/modules/registry/main.tf"; then
  ok "registry TLS internal CA + SAN design present"
else
  fail "registry TLS (CA/SAN) not implemented"
fi

if grep -q 'tls:' "$ROOT/modules/registry/templates/registry.yaml.tftpl" \
  && grep -q 'htpasswd' "$ROOT/modules/registry/templates/registry.yaml.tftpl" \
  && grep -q 'private_ip' "$ROOT/modules/registry/templates/registry.yaml.tftpl" \
  && grep -q 'certificate:' "$ROOT/modules/registry/templates/registry.yaml.tftpl"; then
  ok "registry cloud-init: HTTPS + htpasswd + private bind"
else
  fail "registry cloud-init missing TLS/auth/private bind"
fi

if grep -qE '0\.0\.0\.0:5000|-p 5000:5000' "$ROOT/modules/registry/templates/registry.yaml.tftpl"; then
  fail "registry exposes public 5000 mapping"
else
  ok "registry does not publish public port 5000"
fi

# k3s node trust for registry CA
if grep -q 'registries.yaml' "$ROOT/modules/k3s-cluster/templates/k3s-server.yaml.tftpl" \
  && grep -q 'registry-ca.crt' "$ROOT/modules/k3s-cluster/templates/k3s-server.yaml.tftpl" \
  && grep -q 'registries.yaml' "$ROOT/modules/node-pools/templates/k3s-agent.yaml.tftpl"; then
  ok "k3s server+agents install registry CA and registries.yaml"
else
  fail "k3s registry trust not wired on all nodes"
fi

# OpenTofu checks in root
if grep -q 'ssh_cidrs_when_provisioning' "$STAGING/main.tf" \
  && grep -q 'ssh_keys_when_provisioning' "$STAGING/main.tf" \
  && grep -q 'registry_tls_designed' "$STAGING/main.tf"; then
  ok "root OpenTofu checks for SSH CIDRs, keys, and registry TLS"
else
  fail "root preflight OpenTofu checks incomplete"
fi

# State backend design (always)
if [[ -f "$ROOT/docs/STATE-BACKEND.md" ]] \
  && [[ -f "$STAGING/backend.hcl.example" ]] \
  && [[ -f "$BOOTSTRAP/backend.hcl.example" ]]; then
  ok "state backend design docs + examples present"
else
  fail "missing STATE-BACKEND.md or backend.hcl.example"
fi

if grep -q 'encrypt.*=.*true' "$STAGING/backend.hcl.example" \
  && grep -q 'use_lockfile.*=.*true' "$STAGING/backend.hcl.example"; then
  ok "staging backend example requires encrypt + use_lockfile"
else
  fail "staging backend.hcl.example missing encrypt/use_lockfile"
fi

if grep -q 'staging/fsn1/terraform.tfstate' "$STAGING/backend.hcl.example" \
  && grep -q 'bootstrap/fsn1/terraform.tfstate' "$BOOTSTRAP/backend.hcl.example"; then
  ok "bootstrap and staging state keys are separate"
else
  fail "bootstrap/staging state keys not separated"
fi

if [[ -f "$STAGING/backend.tf.example" ]] && grep -q 'backend "s3"' "$STAGING/backend.tf.example"; then
  ok "staging backend.tf.example declares s3 backend (optional file for provision)"
else
  fail "staging backend.tf.example missing s3 backend"
fi

# Sensitive user_data redaction
if grep -q 'sensitive(templatefile' "$ROOT/modules/registry/main.tf" \
  && grep -q 'sensitive(templatefile' "$ROOT/modules/k3s-cluster/main.tf"; then
  ok "cloud-init user_data wrapped with sensitive() for plan redaction"
else
  fail "user_data not marked sensitive (secrets may print in plan)"
fi

# Optional strict provision readiness
if [[ "${PREFLIGHT_PROVISION:-0}" == "1" ]]; then
  echo "--- PREFLIGHT_PROVISION=1 (apply readiness — still no apply) ---"
  CIDRS="${ALLOW_SSH_CIDRS:-}"
  KEYS="${SSH_KEY_IDS:-}"
  if [[ -z "$CIDRS" ]]; then
    fail "allow_ssh_cidrs empty (set ALLOW_SSH_CIDRS=203.0.113.10/32,...)"
  else
    ok "allow_ssh_cidrs non-empty"
    if echo "$CIDRS" | grep -qE '0\.0\.0\.0/0|::/0'; then
      fail "allow_ssh_cidrs contains forbidden 0.0.0.0/0 or ::/0"
    else
      ok "allow_ssh_cidrs has no world-open entries"
    fi
  fi
  if [[ -z "$KEYS" ]]; then
    fail "ssh_key_ids empty (set SSH_KEY_IDS=12345,...)"
  else
    ok "ssh_key_ids non-empty"
  fi

  # Reject local state for provision path
  if [[ -f "$STAGING/terraform.tfstate" ]] || [[ -f "$STAGING/terraform.tfstate.backup" ]]; then
    fail "local terraform.tfstate present — forbidden for provision=true (migrate to remote)"
  else
    ok "no local terraform.tfstate in staging root"
  fi

  # Require backend.tf (enables s3 backend) + backend.hcl (encrypt/lock)
  if [[ ! -f "$STAGING/backend.tf" ]]; then
    fail "missing backend.tf — copy backend.tf.example (required for provision=true)"
  else
    ok "backend.tf present (remote backend enabled)"
    if ! grep -q 'backend "s3"' "$STAGING/backend.tf"; then
      fail "backend.tf must declare backend \"s3\""
    fi
  fi

  BACKEND_HCL="${BACKEND_HCL:-$STAGING/backend.hcl}"
  if [[ ! -f "$BACKEND_HCL" ]]; then
    fail "missing backend configuration ($BACKEND_HCL) — copy backend.hcl.example"
  else
    ok "backend configuration file present ($BACKEND_HCL)"
    if grep -qiE 'encrypt[[:space:]]*=[[:space:]]*true' "$BACKEND_HCL"; then
      ok "backend encrypt = true"
    else
      fail "backend missing encrypt = true (unencrypted backend rejected)"
    fi
    if grep -qiE 'use_lockfile[[:space:]]*=[[:space:]]*true' "$BACKEND_HCL" \
      || grep -qiE 'dynamodb_table[[:space:]]*=' "$BACKEND_HCL"; then
      ok "backend state locking configured (use_lockfile or dynamodb_table)"
    else
      fail "backend missing state locking (use_lockfile=true required)"
    fi
    if grep -qiE 'encrypt[[:space:]]*=[[:space:]]*false' "$BACKEND_HCL"; then
      fail "backend explicitly disables encryption"
    fi
    if ! grep -q 'staging/fsn1' "$BACKEND_HCL"; then
      fail "backend key should target staging/fsn1 (not bootstrap)"
    else
      ok "backend key targets staging/fsn1"
    fi
  fi
else
  ok "PREFLIGHT_PROVISION not set (structural checks only; set =1 before real apply)"
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "Preflight passed. Still do not apply without human approval + apply-staging.sh."
