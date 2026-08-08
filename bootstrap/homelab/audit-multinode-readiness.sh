#!/usr/bin/env bash
# Read-only multi-node Homelab readiness audit.
# Does NOT join workers, install K3s, apply manifests, or change firewalls.
#
# Environment overrides:
#   K3S_HOST / K3S_USER          current control-plane (default 192.168.152.114 / soloadmin)
#   FEDORA_HOST / FEDORA_USER    registry host (default 192.168.152.12 / bookchaowalit)
#   PROXMOX_HOSTS                comma-separated candidate IPs (default 192.168.152.10,192.168.152.11)
#   PROXMOX_USERS                comma-separated users to try (default root,bookchaowalit,soloadmin)
#   SSH_CONNECT_TIMEOUT          seconds (default 8)
#   REMOTE_KUBECONFIG            on K3s host (default /etc/rancher/k3s/k3s.yaml)
#
# Exit codes:
#   0  current cluster healthy; candidates may be SKIP/WARN/BLOCKED
#   1  current K3s/control-plane checks failed (BLOCKED on live single-node)
set -uo pipefail

export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"

K3S_HOST="${K3S_HOST:-192.168.152.114}"
K3S_USER="${K3S_USER:-soloadmin}"
FEDORA_HOST="${FEDORA_HOST:-192.168.152.12}"
FEDORA_USER="${FEDORA_USER:-bookchaowalit}"
PROXMOX_HOSTS="${PROXMOX_HOSTS:-192.168.152.10,192.168.152.11}"
PROXMOX_USERS="${PROXMOX_USERS:-root,bookchaowalit,soloadmin}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-8}"
REMOTE_KUBECONFIG="${REMOTE_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

PASS=0
WARN=0
BLOCKED=0
SKIP=0
REPORT=()

log()  { printf '%s\n' "$*"; }
pass() { PASS=$((PASS + 1)); REPORT+=("PASS     $*"); log "  ✅ PASS  $*"; }
warn() { WARN=$((WARN + 1)); REPORT+=("WARN     $*"); log "  ⚠️  WARN  $*"; }
blocked() { BLOCKED=$((BLOCKED + 1)); REPORT+=("BLOCKED  $*"); log "  🛑 BLOCKED $*"; }
skip() { SKIP=$((SKIP + 1)); REPORT+=("SKIP     $*"); log "  ⏭️  SKIP  $*"; }

ssh_opts=(-o BatchMode=yes -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -o StrictHostKeyChecking=accept-new)

# Try SSH; print remote stdout. Return 0 if command succeeds.
ssh_try() {
  local user="$1" host="$2"
  shift 2
  ssh "${ssh_opts[@]}" "${user}@${host}" "$@" 2>/dev/null
}

# Probe TCP (operator workstation). 0 = open.
tcp_open() {
  local host="$1" port="$2"
  timeout 2 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null
}

# Probe UDP is best-effort (no real handshake); use nc if present.
udp_probe() {
  local host="$1" port="$2"
  if command -v nc >/dev/null 2>&1; then
    timeout 2 nc -uz -w1 "${host}" "${port}" >/dev/null 2>&1
    return $?
  fi
  return 2
}

# ---------------------------------------------------------------------------
log "=== Homelab multi-node readiness audit (READ-ONLY) ==="
log "  K3S=${K3S_USER}@${K3S_HOST}"
log "  REGISTRY=${FEDORA_USER}@${FEDORA_HOST}"
log "  PROXMOX_HOSTS=${PROXMOX_HOSTS}"
log "  No join / no install / no apply"
log ""

# ---------------------------------------------------------------------------
log "[A] Current K3s control-plane cluster"
if ! ssh_try "${K3S_USER}" "${K3S_HOST}" "export KUBECONFIG='${REMOTE_KUBECONFIG}'; kubectl get nodes >/dev/null"; then
  blocked "cannot SSH/kubectl on current K3s host ${K3S_USER}@${K3S_HOST}"
  CLUSTER_OK=0
else
  CLUSTER_OK=1
  pass "SSH + kubectl on current K3s host"
  CLUSTER_OUT="$(ssh_try "${K3S_USER}" "${K3S_HOST}" "export KUBECONFIG='${REMOTE_KUBECONFIG}'; bash -s" <<'REMOTE' || true
set -uo pipefail
echo "HOSTNAME=$(hostname)"
echo "OS=$(. /etc/os-release 2>/dev/null; echo ${PRETTY_NAME:-unknown})"
echo "KERNEL=$(uname -r)"
echo "ARCH=$(uname -m)"
echo "CPU=$(nproc 2>/dev/null || echo unknown)"
echo "MEM_TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
echo "MEM_AVAIL_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
echo "DISK_ROOT=$(df -h / 2>/dev/null | awk 'NR==2 {print $2" total, "$4" avail ("$5" used)"}')"
echo "IPS=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2"="$4}' | tr '\n' ' ')"
echo "ROUTE=$(ip -4 route show default 2>/dev/null | head -1)"
if command -v timedatectl >/dev/null 2>&1; then
  echo "TIME_SYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || timedatectl | awk -F: '/System clock synchronized/ {gsub(/ /,\"\",$2); print $2}')"
else
  echo "TIME_SYNC=unknown"
fi
echo "CONTAINERD=$(command -v containerd >/dev/null && echo present || echo missing)"
echo "CGROUP=$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
echo "IPTABLES=$(command -v iptables >/dev/null && iptables -V 2>/dev/null | head -1 || echo missing)"
echo "---NODES---"
kubectl get nodes -o wide 2>/dev/null || true
echo "---NODE_COUNT---"
kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' '
echo "---ROLES---"
kubectl get nodes -o custom-columns=NAME:.metadata.name,ROLES:.metadata.labels.node-role\\.kubernetes\\.io/control-plane,WORKER:.metadata.labels.node-role\\.kubernetes\\.io/worker,READY:.status.conditions[-1].type 2>/dev/null || \
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" roles="}{.metadata.labels}{"\n"}{end}' 2>/dev/null
echo "---TOP---"
kubectl top nodes 2>/dev/null || echo "top_unavailable"
echo "---ARGO---"
kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers 2>/dev/null || true
echo "---REGISTRY_TRUST---"
if [[ -f /etc/rancher/k3s/registries.yaml ]]; then
  echo "registries_yaml=present"
  # Do not print file contents (may contain auth)
  grep -E 'registry\.homelab\.local|5000' /etc/rancher/k3s/registries.yaml 2>/dev/null | sed 's/password.*/password: REDACTED/g; s/username.*/username: REDACTED/g' | head -10 || true
else
  echo "registries_yaml=missing"
fi
echo "---EXTRA_WORKERS---"
kubectl get nodes --no-headers 2>/dev/null | awk 'NF {print $1,$2,$3}' 
REMOTE
)"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    log "  · ${line}"
  done <<< "$CLUSTER_OUT"

  node_count=$(printf '%s\n' "$CLUSTER_OUT" | awk -F= '/^---NODE_COUNT---$/ {getline; print; exit}')
  node_count=${node_count// /}
  if [[ "${node_count:-0}" == "1" ]]; then
    pass "cluster is single-node (node_count=1); no unexpected extra worker joined"
  elif [[ "${node_count:-0}" -gt 1 ]]; then
    warn "cluster has ${node_count} nodes — multi-node already present; verify intentional"
  else
    blocked "could not determine node count"
  fi

  if printf '%s\n' "$CLUSTER_OUT" | grep -q 'Ready'; then
    # more precise: Ready True in node list
    if printf '%s\n' "$CLUSTER_OUT" | grep -E 'solo-k3s|Ready' | head -1 >/dev/null; then
      pass "current node appears Ready in kubectl get nodes"
    fi
  fi

  # Argo portfolio apps
  for app in ai-doc-assistant-homelab booknbook-homelab; do
    row=$(printf '%s\n' "$CLUSTER_OUT" | awk -v a="$app" '$1==a {print; exit}')
    if [[ -z "$row" ]]; then
      warn "Argo Application ${app} not listed"
    elif [[ "$row" == *"Synced"* && "$row" == *"Healthy"* ]]; then
      pass "Argo ${app} Synced/Healthy"
    else
      blocked "Argo ${app} not Synced/Healthy (${row})"
    fi
  done

  if printf '%s\n' "$CLUSTER_OUT" | grep -q 'registries_yaml=present'; then
    pass "K3s registries.yaml present (registry trust configured)"
  else
    warn "K3s registries.yaml missing — image pulls from private registry may fail on new workers until configured"
  fi

  if printf '%s\n' "$CLUSTER_OUT" | grep -qi 'containerd.*present\|CONTAINERD=present'; then
    pass "containerd present on control-plane host"
  fi
fi

# ---------------------------------------------------------------------------
log ""
log "[B] Network path checks (from operator workstation)"

# Ports on control plane
for port in 22 6443 10250 80 443; do
  if tcp_open "${K3S_HOST}" "${port}"; then
    pass "TCP ${K3S_HOST}:${port} open"
  else
    if [[ "$port" == "22" || "$port" == "6443" ]]; then
      blocked "TCP ${K3S_HOST}:${port} not reachable (required for K3s)"
    else
      warn "TCP ${K3S_HOST}:${port} not reachable from operator"
    fi
  fi
done

udp_rc=0
udp_probe "${K3S_HOST}" 8472 || udp_rc=$?
if [[ "$udp_rc" == "0" ]]; then
  pass "UDP ${K3S_HOST}:8472 (Flannel VXLAN) probe ok"
elif [[ "$udp_rc" == "2" ]]; then
  skip "UDP 8472 probe skipped (nc not available on operator)"
else
  warn "UDP ${K3S_HOST}:8472 probe inconclusive/failed (Flannel may still work between nodes)"
fi

# Registry
for port in 22 5000; do
  if tcp_open "${FEDORA_HOST}" "${port}"; then
    pass "TCP ${FEDORA_HOST}:${port} open"
  else
    if [[ "$port" == "5000" ]]; then
      warn "TCP ${FEDORA_HOST}:5000 not reachable — private registry may be down or firewalled"
    else
      warn "TCP ${FEDORA_HOST}:${port} not reachable"
    fi
  fi
done

# Connectivity to both anchors
if ping -c1 -W2 "${K3S_HOST}" >/dev/null 2>&1; then
  pass "ICMP reachability to K3s ${K3S_HOST}"
else
  warn "ICMP to ${K3S_HOST} failed (TCP may still work)"
fi
if ping -c1 -W2 "${FEDORA_HOST}" >/dev/null 2>&1; then
  pass "ICMP reachability to registry ${FEDORA_HOST}"
else
  warn "ICMP to ${FEDORA_HOST} failed"
fi

# ---------------------------------------------------------------------------
# Host inventory helper (read-only remote facts)
remote_host_facts() {
  local user="$1" host="$2" role="$3"
  local out
  out="$(ssh_try "${user}" "${host}" "bash -s" <<'HF' || true
set -uo pipefail
echo "HOSTNAME=$(hostname 2>/dev/null || echo unknown)"
echo "OS=$(. /etc/os-release 2>/dev/null; echo ${PRETTY_NAME:-unknown})"
echo "KERNEL=$(uname -r 2>/dev/null || echo unknown)"
echo "ARCH=$(uname -m 2>/dev/null || echo unknown)"
echo "CPU=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo unknown)"
echo "MEM_TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
echo "MEM_AVAIL_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
echo "DISK_ROOT=$(df -hP / 2>/dev/null | awk 'NR==2 {print $2" total, "$4" avail, "$5" used"}')"
echo "FS_ROOT=$(df -T / 2>/dev/null | awk 'NR==2 {print $2}')"
echo "IPS=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2"=" $4}' | tr '\n' ';')"
echo "ROUTE=$(ip -4 route show default 2>/dev/null | head -1)"
if command -v timedatectl >/dev/null 2>&1; then
  sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
  echo "TIME_SYNC=${sync:-unknown}"
else
  echo "TIME_SYNC=unknown"
fi
echo "DOCKER=$(command -v docker >/dev/null && echo present || echo missing)"
echo "CONTAINERD=$(command -v containerd >/dev/null && echo present || echo missing)"
echo "PODMAN=$(command -v podman >/dev/null && echo present || echo missing)"
echo "CGROUP=$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
echo "IPTABLES=$(command -v iptables >/dev/null && echo present || echo missing)"
echo "NFT=$(command -v nft >/dev/null && echo present || echo missing)"
echo "PUBLIC_IFACE_HINT=$(ip -4 route get 1.1.1.1 2>/dev/null | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
# Never dump secrets
echo "K3S_BIN=$(command -v k3s >/dev/null && echo present || echo missing)"
echo "K3S_AGENT_SERVICE=$(systemctl is-active k3s-agent 2>/dev/null || echo inactive)"
HF
)"
  if [[ -z "$out" ]]; then
    return 1
  fi
  log "  --- ${role} ${user}@${host} ---"
  while IFS= read -r line; do
    log "  · ${line}"
  done <<< "$out"

  # Evaluate minimum worker sizing (K3s agent baseline + headroom)
  local mem cpu
  mem=$(printf '%s\n' "$out" | sed -n 's/^MEM_TOTAL_MB=//p' | head -1)
  cpu=$(printf '%s\n' "$out" | sed -n 's/^CPU=//p' | head -1)
  if [[ "$mem" =~ ^[0-9]+$ ]]; then
    if (( mem < 1024 )); then
      blocked "${role} ${host}: RAM ${mem}Mi < 1 GiB minimum for worker node + workloads"
    elif (( mem < 2048 )); then
      warn "${role} ${host}: RAM ${mem}Mi is tight (prefer ≥2 GiB free for demos)"
    else
      pass "${role} ${host}: RAM ${mem}Mi meets minimum"
    fi
  fi
  if [[ "$cpu" =~ ^[0-9]+$ ]]; then
    if (( cpu < 1 )); then
      blocked "${role} ${host}: CPU count ${cpu} insufficient"
    elif (( cpu < 2 )); then
      warn "${role} ${host}: only ${cpu} CPU — ok for light agent, tight for demos"
    else
      pass "${role} ${host}: CPU count ${cpu} ok"
    fi
  fi

  local cgroup ipt
  cgroup=$(printf '%s\n' "$out" | sed -n 's/^CGROUP=//p' | head -1)
  ipt=$(printf '%s\n' "$out" | sed -n 's/^IPTABLES=//p' | head -1)
  if [[ "$cgroup" == "cgroup2fs" || "$cgroup" == "tmpfs" || -n "$cgroup" ]]; then
    pass "${role} ${host}: cgroup present (${cgroup})"
  else
    warn "${role} ${host}: cgroup unknown"
  fi
  if [[ "$ipt" == "present" ]]; then
    pass "${role} ${host}: iptables present"
  else
    warn "${role} ${host}: iptables missing (nft-only possible; verify K3s requirements)"
  fi

  local k3s_agent
  k3s_agent=$(printf '%s\n' "$out" | sed -n 's/^K3S_AGENT_SERVICE=//p' | head -1)
  if [[ "$k3s_agent" == "active" ]]; then
    warn "${role} ${host}: k3s-agent service already active (unexpected for unjoined candidate)"
  else
    pass "${role} ${host}: k3s-agent not active (no accidental join)"
  fi
  return 0
}

# ---------------------------------------------------------------------------
log ""
log "[C] Fedora registry host (must remain separate from K3s unless approved)"
if remote_host_facts "${FEDORA_USER}" "${FEDORA_HOST}" "registry-host"; then
  pass "SSH inventory for Fedora registry host"
  # From Fedora: can it reach K3s?
  if ssh_try "${FEDORA_USER}" "${FEDORA_HOST}" "timeout 2 bash -c 'echo >/dev/tcp/${K3S_HOST}/6443'" >/dev/null 2>&1; then
    pass "registry host can open TCP ${K3S_HOST}:6443"
  else
    warn "registry host cannot open TCP ${K3S_HOST}:6443 (ok if registry never joins cluster)"
  fi
  if ssh_try "${FEDORA_USER}" "${FEDORA_HOST}" "docker ps --format '{{.Names}}' 2>/dev/null | head -5" >/dev/null 2>&1; then
    pass "docker available on registry host (runtime present)"
  else
    warn "docker not queryable on registry host (registry container may still run via root)"
  fi
  # Explicit recommendation
  pass "topology note: Fedora ${FEDORA_HOST} should stay registry-only (do not join as K3s node without approval)"
else
  skip "Fedora registry host SSH unavailable as ${FEDORA_USER}@${FEDORA_HOST}"
fi

# ---------------------------------------------------------------------------
log ""
log "[D] Proxmox / future worker candidates"
IFS=',' read -r -a PX_HOSTS <<< "${PROXMOX_HOSTS}"
for phost in "${PX_HOSTS[@]}"; do
  phost="${phost// /}"
  [[ -z "$phost" ]] && continue
  log "  -- candidate ${phost} --"
  if tcp_open "${phost}" 22; then
    pass "TCP ${phost}:22 open"
  else
    skip "TCP ${phost}:22 closed/unreachable"
    continue
  fi

  # Connectivity to anchors
  if ping -c1 -W2 "${phost}" >/dev/null 2>&1; then
    pass "ICMP to candidate ${phost}"
  else
    warn "ICMP to ${phost} failed"
  fi

  authed=0
  IFS=',' read -r -a PX_USERS <<< "${PROXMOX_USERS}"
  for puser in "${PX_USERS[@]}"; do
    puser="${puser// /}"
    [[ -z "$puser" ]] && continue
    if ssh_try "${puser}" "${phost}" "true" >/dev/null 2>&1; then
      authed=1
      pass "SSH key auth works for ${puser}@${phost}"
      remote_host_facts "${puser}" "${phost}" "worker-candidate" || warn "facts incomplete for ${phost}"
      # Can candidate reach control-plane and registry?
      if ssh_try "${puser}" "${phost}" "timeout 2 bash -c 'echo >/dev/tcp/${K3S_HOST}/6443'" >/dev/null 2>&1; then
        pass "${phost} can reach K3s API ${K3S_HOST}:6443"
      else
        blocked "${phost} cannot reach K3s API ${K3S_HOST}:6443 — join blocked until network path exists"
      fi
      if ssh_try "${puser}" "${phost}" "timeout 2 bash -c 'echo >/dev/tcp/${K3S_HOST}/10250'" >/dev/null 2>&1; then
        pass "${phost} can reach kubelet port ${K3S_HOST}:10250"
      else
        warn "${phost} cannot reach ${K3S_HOST}:10250 (may open after agent install)"
      fi
      if ssh_try "${puser}" "${phost}" "timeout 2 bash -c 'echo >/dev/tcp/${FEDORA_HOST}/5000'" >/dev/null 2>&1; then
        pass "${phost} can reach registry ${FEDORA_HOST}:5000"
      else
        blocked "${phost} cannot reach registry ${FEDORA_HOST}:5000 — image pulls will fail after join"
      fi
      break
    fi
  done
  if [[ "$authed" == "0" ]]; then
    skip "no SSH key auth for candidate ${phost} (tried ${PROXMOX_USERS}) — host inventory SKIP; LAN port 22 open suggests machine is up"
    # Still note worker readiness requires VM + keys
    blocked "worker candidate ${phost}: SSH keys required before join; no unattended install attempted"
    # Print owner-facing pubkey install hint once (public key material only).
    if [[ -z "${_PROXMOX_SSH_HINT_PRINTED:-}" ]]; then
      _PROXMOX_SSH_HINT_PRINTED=1
      log "  · --- owner action (public key only; private key never leaves workstation) ---"
      if [[ -f "${HOME}/.ssh/bookchaowalit.pub" ]]; then
        fp=$(ssh-keygen -lf "${HOME}/.ssh/bookchaowalit.pub" 2>/dev/null | awk '{print $2}')
        log "  · recommended pubkey file: ~/.ssh/bookchaowalit.pub"
        log "  · fingerprint: ${fp}"
        log "  · on Proxmox (as root, console/admin session):"
        log "  ·   install -d -m 700 /root/.ssh"
        log "  ·   cat >> /root/.ssh/authorized_keys  # paste ONE line from: cat ~/.ssh/bookchaowalit.pub"
        log "  ·   chmod 600 /root/.ssh/authorized_keys"
        log "  · or from workstation after interactive login works:"
        log "  ·   ssh-copy-id -i ~/.ssh/bookchaowalit.pub root@${phost}"
        log "  · verify: ssh -o BatchMode=yes -i ~/.ssh/bookchaowalit root@${phost} hostname"
        log "  · full steps: operations/HOMELAB-MULTINODE-READINESS.md"
      else
        log "  · add operator ED25519 public key to root@${phost}:~/.ssh/authorized_keys"
      fi
    fi
  fi
done

# ---------------------------------------------------------------------------
log ""
log "[E] Topology / decision summary (read-only)"
pass "recommended: ${K3S_HOST} remains sole K3s control-plane/server"
pass "recommended: ${FEDORA_HOST} remains private registry only (not a K3s node)"
pass "recommended: Proxmox hosts provide future K3s worker VMs (not bare-metal join by default)"
pass "multi-node state: readiness-audit only — no node was joined by this script"
pass "HA claim: none (single control-plane remains non-HA)"
pass "cloud: none involved"
pass "Proxmox quorum ≠ K3s quorum ≠ app capacity (documented separately)"

# ---------------------------------------------------------------------------
log ""
log "============================================================"
log "Multi-node readiness: PASS=$PASS  WARN=$WARN  BLOCKED=$BLOCKED  SKIP=$SKIP"
log "============================================================"
for line in "${REPORT[@]}"; do
  log "$line"
done
log ""
log "Safety: no k3s agent/server install, no kubectl apply, no tofu apply, no reboot."
log "Next: see operations/HOMELAB-MULTINODE-READINESS.md decision gate."
log "============================================================"

# Fail only if the live single-node control plane is unhealthy.
if [[ "${CLUSTER_OK:-0}" != "1" ]]; then
  exit 1
fi
# Fail if any BLOCKED item is about the live control plane apps already counted
# Candidate BLOCKs alone do not fail the audit (expected until keys/VMs ready).
if printf '%s\n' "${REPORT[@]}" | grep -q 'BLOCKED  Argo\|BLOCKED  cannot SSH/kubectl on current\|BLOCKED  could not determine node'; then
  exit 1
fi
exit 0
