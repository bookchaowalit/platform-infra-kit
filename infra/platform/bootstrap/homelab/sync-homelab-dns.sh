#!/usr/bin/env bash
# Sync Homelab private hostnames into /etc/hosts (idempotent block replace).
#
# Manages ONLY the marked block:
#   # BEGIN Solo Empire Homelab ... # END Solo Empire Homelab
#
# Never touches Docker Compose Lab blocks:
#   # BEGIN Solo Empire Services ... # END Solo Empire Services
# Never rewrites arbitrary *.local → 127.0.0.1 entries.
#
# Usage:
#   DRY_RUN=1 bash infra/platform/bootstrap/homelab/sync-homelab-dns.sh
#   bash infra/platform/bootstrap/homelab/sync-homelab-dns.sh   # needs sudo to write
#
# Overrides:
#   HOMELAB_NODE_IP=192.168.152.114
#   REGISTRY_IP=192.168.152.12
#   HOSTS_FILE=/etc/hosts
set -euo pipefail

BOOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAGMENT="${FRAGMENT:-$BOOT/hosts.homelab.fragment}"
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
HOMELAB_NODE_IP="${HOMELAB_NODE_IP:-192.168.152.114}"
REGISTRY_IP="${REGISTRY_IP:-192.168.152.12}"
DRY_RUN="${DRY_RUN:-0}"

BEGIN_MARKER="# BEGIN Solo Empire Homelab"
END_MARKER="# END Solo Empire Homelab"

if [[ ! -f "$FRAGMENT" ]]; then
  echo "ERROR: fragment not found: $FRAGMENT" >&2
  exit 1
fi

# Build managed block with optional IP overrides from env.
build_block() {
  cat <<EOF
${BEGIN_MARKER}
# Managed by infra/platform/bootstrap/homelab/sync-homelab-dns.sh
# Private LAN only. Do NOT mix with Docker Compose Lab (127.0.0.1 *.local).
${HOMELAB_NODE_IP} ai-doc-assistant.homelab.local
${HOMELAB_NODE_IP} booknbook.homelab.local
${HOMELAB_NODE_IP} netbox.homelab.local
${HOMELAB_NODE_IP} platform-smoke.local
${REGISTRY_IP} registry.homelab.local
${END_MARKER}
EOF
}

echo "=== Homelab DNS sync (private /etc/hosts block) ==="
echo "  HOSTS_FILE=${HOSTS_FILE}"
echo "  HOMELAB_NODE_IP=${HOMELAB_NODE_IP}"
echo "  REGISTRY_IP=${REGISTRY_IP}"
echo "  DRY_RUN=${DRY_RUN}"
echo ""
echo "--- managed entries ---"
build_block
echo "--- end managed entries ---"
echo ""

tmp="$(mktemp)"
block="$(mktemp)"
trap 'rm -f "$tmp" "$block" "$tmp.base" "$tmp.new"' EXIT

build_block >"$block"

if [[ -r "$HOSTS_FILE" ]]; then
  awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    skip { next }
    { print }
  ' "$HOSTS_FILE" >"$tmp.base"
else
  : >"$tmp.base"
fi

{
  cat "$tmp.base"
  # Ensure trailing newline before block
  if [[ -s "$tmp.base" ]] && [[ "$(tail -c1 "$tmp.base" | wc -l)" -eq 0 ]]; then
    echo ""
  fi
  cat "$block"
  echo ""
} >"$tmp.new"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN=1: not writing ${HOSTS_FILE}"
  echo "Diff preview (existing vs proposed managed block replace):"
  if command -v diff >/dev/null 2>&1 && [[ -r "$HOSTS_FILE" ]]; then
    diff -u "$HOSTS_FILE" "$tmp.new" | head -80 || true
  else
    echo "(no diff available)"
  fi
  exit 0
fi

if [[ "$(id -u)" -eq 0 ]]; then
  cp "$tmp.new" "$HOSTS_FILE"
else
  if ! sudo -n true 2>/dev/null; then
    echo "Need sudo to write ${HOSTS_FILE}"
  fi
  sudo cp "$tmp.new" "$HOSTS_FILE"
fi

echo "OK: updated Homelab block in ${HOSTS_FILE}"
echo "Verify: getent hosts ai-doc-assistant.homelab.local netbox.homelab.local registry.homelab.local"
getent hosts ai-doc-assistant.homelab.local booknbook.homelab.local netbox.homelab.local platform-smoke.local registry.homelab.local 2>/dev/null || true
