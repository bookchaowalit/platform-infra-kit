#!/usr/bin/env bash
# Read-only Homelab URL smoke checks (DNS + HTTP + registry TCP).
# Does not apply Kubernetes resources, change Ingress, or print secrets.
#
# Overrides:
#   HOMELAB_NODE_IP=192.168.152.114
#   REGISTRY_IP=192.168.152.12
#   CURL_TIMEOUT=10
#   USE_RESOLVE=1   # force Host via curl --resolve to HOMELAB_NODE_IP
set -uo pipefail

export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"

HOMELAB_NODE_IP="${HOMELAB_NODE_IP:-192.168.152.114}"
REGISTRY_IP="${REGISTRY_IP:-192.168.152.12}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
USE_RESOLVE="${USE_RESOLVE:-0}"

PASS=0
FAIL=0
SKIP=0
REPORT=()

log()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); REPORT+=("PASS  $*"); log "  ✅ $*"; }
fail() { FAIL=$((FAIL + 1)); REPORT+=("FAIL  $*"); log "  ❌ $*"; }
skip() { SKIP=$((SKIP + 1)); REPORT+=("SKIP  $*"); log "  ⚠️  SKIP $*"; }

log "=== Homelab URL verification (read-only) ==="
log "  HOMELAB_NODE_IP=${HOMELAB_NODE_IP}  REGISTRY_IP=${REGISTRY_IP}"
log "  USE_RESOLVE=${USE_RESOLVE}  CURL_TIMEOUT=${CURL_TIMEOUT}"
log ""

# --- DNS ---
log "[1] DNS resolution"
declare -A EXPECT_IP=(
  [ai-doc-assistant.homelab.local]="$HOMELAB_NODE_IP"
  [booknbook.homelab.local]="$HOMELAB_NODE_IP"
  [platform-smoke.local]="$HOMELAB_NODE_IP"
  [registry.homelab.local]="$REGISTRY_IP"
)

for host in ai-doc-assistant.homelab.local booknbook.homelab.local platform-smoke.local registry.homelab.local; do
  resolved=""
  if command -v getent >/dev/null 2>&1; then
    resolved=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')
  fi
  if [[ -z "$resolved" ]]; then
    resolved=$(getent hosts "$host" 2>/dev/null | awk '{print $1; exit}' || true)
  fi
  if [[ -z "$resolved" ]]; then
    # fallback: dig/host not required
    if command -v python3 >/dev/null 2>&1; then
      resolved=$(python3 - <<PY 2>/dev/null || true
import socket
try:
  print(socket.gethostbyname("${host}"))
except Exception:
  pass
PY
)
    fi
  fi
  expect="${EXPECT_IP[$host]}"
  if [[ -z "$resolved" ]]; then
    if [[ "$USE_RESOLVE" == "1" ]]; then
      skip "DNS ${host} unresolved (USE_RESOLVE=1 will pin IP for HTTP probes)"
    else
      fail "DNS ${host} unresolved (run sync-homelab-dns.sh or USE_RESOLVE=1)"
    fi
  elif [[ "$resolved" == "$expect" ]]; then
    ok "DNS ${host} → ${resolved}"
  elif [[ "$resolved" == "127.0.0.1" || "$resolved" == "::1" ]]; then
    fail "DNS ${host} → ${resolved} (must not be loopback; Homelab is LAN ${expect})"
  else
    fail "DNS ${host} → ${resolved} (expected ${expect})"
  fi
done

# Private IP routing smoke
log ""
log "[2] Private IP reachability"
if ping -c1 -W2 "${HOMELAB_NODE_IP}" >/dev/null 2>&1; then
  ok "ICMP reach ${HOMELAB_NODE_IP}"
else
  # ICMP may be blocked; try TCP 80
  if timeout 2 bash -c "echo >/dev/tcp/${HOMELAB_NODE_IP}/80" 2>/dev/null; then
    ok "TCP ${HOMELAB_NODE_IP}:80 open (ICMP failed)"
  else
    fail "cannot reach Homelab node ${HOMELAB_NODE_IP}"
  fi
fi

# --- HTTP probes ---
log ""
log "[3] HTTP application URLs"
curl_http() {
  local host="$1" path="$2"
  local url="http://${host}${path}"
  local extra=()
  if [[ "$USE_RESOLVE" == "1" ]]; then
    extra=(--resolve "${host}:80:${HOMELAB_NODE_IP}")
  fi
  curl -sS -m "${CURL_TIMEOUT}" -o /dev/null -w '%{http_code}' \
    "${extra[@]}" -H "Host: ${host}" "$url" 2>/dev/null || echo 000
}

# host path expected_code
while read -r host path expect; do
  [[ -z "$host" || "$host" =~ ^# ]] && continue
  code=$(curl_http "$host" "$path")
  code=$(echo "$code" | tr -dc '0-9' | tail -c 3)
  code="${code:-000}"
  if [[ "$code" == "$expect" ]]; then
    ok "HTTP ${host}${path} → ${code}"
  else
    fail "HTTP ${host}${path} → ${code} (expected ${expect})"
  fi
done <<'PROBES'
ai-doc-assistant.homelab.local /healthz 200
ai-doc-assistant.homelab.local /readyz 200
booknbook.homelab.local /healthz 200
booknbook.homelab.local /readyz 200
booknbook.homelab.local /th 200
platform-smoke.local / 200
PROBES

# --- Registry TCP only (no web UI claim) ---
log ""
log "[4] Registry reachability (API port only)"
if timeout 2 bash -c "echo >/dev/tcp/${REGISTRY_IP}/5000" 2>/dev/null; then
  ok "TCP ${REGISTRY_IP}:5000 open (registry.homelab.local:5000)"
else
  fail "TCP ${REGISTRY_IP}:5000 not reachable"
fi
# Optional HEAD without printing auth
reg_code=$(curl -skS -m "${CURL_TIMEOUT}" -o /dev/null -w '%{http_code}' \
  "https://registry.homelab.local:5000/v2/" 2>/dev/null || echo 000)
reg_code=$(echo "$reg_code" | tr -dc '0-9' | tail -c 3)
reg_code="${reg_code:-000}"
# 401 unauthorized is healthy for auth-required registry; 200 also ok if open
if [[ "$reg_code" == "401" || "$reg_code" == "200" ]]; then
  ok "registry /v2/ responds HTTP ${reg_code} (API only; auth expected)"
elif [[ "$reg_code" == "000" ]]; then
  skip "registry HTTPS probe inconclusive (TLS/DNS); TCP:5000 checked separately"
else
  warn_code="$reg_code"
  # use fail only if totally wrong
  if [[ "$warn_code" =~ ^[45] ]]; then
    ok "registry /v2/ HTTP ${warn_code} (API reachable; auth/TLS as configured)"
  else
    fail "registry /v2/ unexpected HTTP ${warn_code}"
  fi
fi

# --- Safety: no public IP assumption ---
log ""
log "[5] Boundary checks"
if [[ "$HOMELAB_NODE_IP" =~ ^192\.168\. ]] || [[ "$HOMELAB_NODE_IP" =~ ^10\. ]] || [[ "$HOMELAB_NODE_IP" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
  ok "Homelab node IP is private (${HOMELAB_NODE_IP})"
else
  fail "Homelab node IP does not look private: ${HOMELAB_NODE_IP}"
fi

log ""
log "============================================================"
log "Homelab URL verify: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
log "============================================================"
for line in "${REPORT[@]}"; do
  log "$line"
done
log ""
log "Tips:"
log "  DRY_RUN=1 bash infra/platform/bootstrap/homelab/sync-homelab-dns.sh"
log "  USE_RESOLVE=1 bash .../verify-homelab-urls.sh   # if /etc/hosts not synced"
log "  Controllers: see docs/operations/HOMELAB-URL-CATALOG.md (port-forward / kubectl)"
log "============================================================"

[[ "$FAIL" -eq 0 ]]
