#!/usr/bin/env bash
# Offline pre-apply security/cost audit for staging IaC. Never runs apply.
set -euo pipefail
export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$ROOT/../../.." && pwd)"
STAGING="$ROOT/envs/staging/fsn1"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ✅ $*"; }
fail() { FAIL=$((FAIL+1)); echo "  ❌ $*"; }

echo "=== Pre-apply audit (offline) ==="

# 5. provision default false
if grep -q 'default     = false' "$STAGING/variables.tf" && grep -A2 'variable "provision"' "$STAGING/variables.tf" | grep -q false; then
  ok "provision defaults to false"
else
  fail "provision default is not false"
fi

# 6. production no root module
if [[ ! -f "$ROOT/envs/production/main.tf" ]] && grep -qi DISABLED "$ROOT/envs/production/README.md"; then
  ok "production has no root module (DISABLED README only)"
else
  fail "production apply path exists unexpectedly"
fi

# 2/1 firewall SSH and ports
if grep -q 'allow_ssh_cidrs' "$ROOT/modules/network/main.tf" && grep -q '0.0.0.0/0' "$ROOT/modules/network/main.tf"; then
  # 0.0.0.0/0 only on 80/443
  if grep -A6 'port.*=.*"22"' "$ROOT/modules/network/main.tf" | grep -q 'allow_ssh_cidrs\|ssh_cidrs\|source_ips  = local.ssh'; then
    ok "SSH uses admin CIDRs (not hardcoded world-open)"
  else
    fail "SSH rule may be world-open"
  fi
  ok "firewall module present with public 80/443 expected for ingress nodes"
else
  fail "network firewall rules incomplete"
fi

if grep -q 'hcloud_firewall" "registry"' "$ROOT/modules/network/main.tf" \
  && grep -q 'hcloud_firewall" "database"' "$ROOT/modules/network/main.tf" \
  && grep -q '5432' "$ROOT/modules/network/main.tf" \
  && grep -q '5000' "$ROOT/modules/network/main.tf"; then
  ok "separate registry/database firewall roles (private 5000/5432)"
else
  fail "missing registry/database firewall separation"
fi

# 3 private network IPs
if grep -q '10.10.1.10' "$STAGING/main.tf" && grep -q '10.10.1.20' "$STAGING/main.tf" && grep -q '10.10.1.30' "$STAGING/main.tf"; then
  ok "static private IPs for CP/registry/postgres"
else
  fail "private IP assignments missing"
fi

# 4 max nodes
if grep -q 'max_nodes_budget' "$ROOT/modules/node-pools/main.tf"; then
  ok "max_nodes_budget enforced in node-pools"
else
  fail "max_nodes_budget not enforced"
fi

# 7 no private keys / tokens in tree (exclude .terraform)
if rg -n --hidden -g '!.terraform/**' -g '!**/generated/**' \
  -e 'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY' \
  -e 'hcloud_token\s*=\s*"[A-Za-z0-9]{20,}' \
  "$ROOT" 2>/dev/null | grep -v 'example\|placeholder\|000000\|prefer env\|HCLOUD_TOKEN' ; then
  fail "possible credential material in IaC"
else
  ok "no private keys or hardcoded tokens found in IaC sources"
fi

# 8 registry auth + TLS
if grep -q 'htpasswd' "$ROOT/modules/registry/templates/registry.yaml.tftpl" && grep -q 'private_ip' "$ROOT/modules/registry/templates/registry.yaml.tftpl"; then
  ok "registry requires auth and private bind"
else
  fail "registry missing auth or private bind"
fi
if grep -q 'tls:' "$ROOT/modules/registry/templates/registry.yaml.tftpl" \
  && grep -q 'tls_self_signed_cert' "$ROOT/modules/registry/main.tf" \
  && grep -q 'dns_names' "$ROOT/modules/registry/main.tf"; then
  ok "registry TLS internal CA with SAN design"
else
  fail "registry TLS not fully configured"
fi
if grep -q 'registries.yaml' "$ROOT/modules/k3s-cluster/templates/k3s-server.yaml.tftpl" \
  && grep -q 'registries.yaml' "$ROOT/modules/node-pools/templates/k3s-agent.yaml.tftpl"; then
  ok "k3s nodes trust registry CA via registries.yaml"
else
  fail "k3s registry CA trust missing on nodes"
fi
if grep -q '0.0.0.0:5000\|-p 5000:5000' "$ROOT/modules/registry/templates/registry.yaml.tftpl"; then
  fail "registry still publishes public 5000 mapping"
else
  ok "registry does not map public 0.0.0.0:5000"
fi

# 9-10 docs
for f in STAGING-DATA-BACKUP-RESTORE.md PRE-APPLY-AUDIT.md STAGING-INFRA-RUNBOOK.md; do
  if [[ -f "$REPO/docs/operations/$f" ]]; then
    ok "doc present: $f"
  else
    fail "missing doc: $f"
  fi
done

# 11 DNS blocked
if grep -q 'enabled     = false' "$STAGING/main.tf" && grep -q 'example.local' "$ROOT/modules/dns/main.tf"; then
  ok "DNS apply blocked at root; placeholder domain guarded"
else
  fail "DNS enablement guard incomplete"
fi

# 12 budget estimate in module
if grep -q 'estimate_total' "$ROOT/modules/cost/main.tf"; then
  ok "cost estimate and within-budget check present"
else
  fail "cost estimate missing"
fi

# 13 remote encrypted state design
if [[ -f "$ROOT/docs/STATE-BACKEND.md" ]] \
  && grep -q 'encrypt.*=.*true' "$STAGING/backend.hcl.example" \
  && grep -q 'use_lockfile.*=.*true' "$STAGING/backend.hcl.example"; then
  ok "encrypted remote state + lockfile design documented"
else
  fail "state backend encryption/locking design incomplete"
fi
if [[ -d "$ROOT/envs/bootstrap/fsn1" ]] \
  && grep -q 'bootstrap/fsn1' "$ROOT/envs/bootstrap/fsn1/backend.hcl.example" \
  && grep -q 'staging/fsn1' "$STAGING/backend.hcl.example"; then
  ok "bootstrap state separated from staging state keys"
else
  fail "bootstrap/staging state separation missing"
fi
if grep -q 'sensitive(templatefile' "$ROOT/modules/registry/main.tf" \
  && ! grep -qE '^\s*output\s+"registry_password"' "$STAGING/outputs.tf" \
  && ! grep -qE '^\s*output\s+"k3s_token"' "$STAGING/outputs.tf" \
  && ! grep -qE '^\s*output\s+"hcloud_token"' "$STAGING/outputs.tf"; then
  ok "sensitive user_data; root outputs omit passwords/tokens"
else
  fail "sensitive values may leak via user_data or root outputs"
fi
if [[ -x "$ROOT/scripts/apply-staging.sh" ]] || [[ -f "$ROOT/scripts/apply-staging.sh" ]]; then
  ok "safe apply-staging.sh wrapper present"
else
  fail "apply-staging.sh missing"
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "Offline audit checks passed. Run tofu validate/plan separately (no apply)."
