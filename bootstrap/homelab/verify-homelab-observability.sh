#!/usr/bin/env bash
# Homelab observability / SRE baseline (read-only).
# Uses metrics-server + kubectl + Argo status. Does NOT install Prometheus,
# Grafana, Loki, Tempo, or kube-prometheus-stack. Does not mutate the cluster.
#
# Overrides:
#   K3S_HOST (default 192.168.152.114)
#   K3S_USER (default soloadmin)
#   REMOTE_KUBECONFIG (default /etc/rancher/k3s/k3s.yaml)
#   MEM_WARN_PCT / MEM_CRIT_PCT (default 75 / 85)
#   CPU_WARN_PCT / CPU_CRIT_PCT (default 70 / 85)
set -euo pipefail

export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"

K3S_HOST="${K3S_HOST:-192.168.152.114}"
K3S_USER="${K3S_USER:-soloadmin}"
REMOTE_KUBECONFIG="${REMOTE_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
MEM_WARN_PCT="${MEM_WARN_PCT:-75}"
MEM_CRIT_PCT="${MEM_CRIT_PCT:-85}"
CPU_WARN_PCT="${CPU_WARN_PCT:-70}"
CPU_CRIT_PCT="${CPU_CRIT_PCT:-85}"

PASS=0
FAIL=0
SKIP=0
WARN=0
REPORT=()

log()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); REPORT+=("PASS  $*"); log "  ✅ $*"; }
fail() { FAIL=$((FAIL + 1)); REPORT+=("FAIL  $*"); log "  ❌ $*"; }
skip() { SKIP=$((SKIP + 1)); REPORT+=("SKIP  $*"); log "  ⚠️  SKIP $*"; }
warn() { WARN=$((WARN + 1)); REPORT+=("WARN  $*"); log "  ⚠️  WARN $*"; }

# ---------------------------------------------------------------------------
log "=== Homelab observability baseline (read-only) ==="
log "  host=${K3S_USER}@${K3S_HOST}"
log "  thresholds: mem warn/crit=${MEM_WARN_PCT}/${MEM_CRIT_PCT}% cpu warn/crit=${CPU_WARN_PCT}/${CPU_CRIT_PCT}%"
log ""

# [0] SSH access
log "[0] SSH access"
if ssh -o BatchMode=yes -o ConnectTimeout=15 "${K3S_USER}@${K3S_HOST}" \
  "export KUBECONFIG='${REMOTE_KUBECONFIG}'; kubectl version --client >/dev/null"; then
  ok "SSH + remote kubectl available"
else
  fail "cannot SSH to ${K3S_USER}@${K3S_HOST} or kubectl missing"
  log ""
  log "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP WARN=$WARN"
  exit 1
fi

# Run remote observation block; parse PASS/FAIL/SKIP/WARN lines + evidence.
# shellcheck disable=SC2087
REMOTE_OUT="$(ssh -o BatchMode=yes -o ConnectTimeout=20 "${K3S_USER}@${K3S_HOST}" \
  "export KUBECONFIG='${REMOTE_KUBECONFIG}'; export MEM_WARN_PCT='${MEM_WARN_PCT}'; export MEM_CRIT_PCT='${MEM_CRIT_PCT}'; export CPU_WARN_PCT='${CPU_WARN_PCT}'; export CPU_CRIT_PCT='${CPU_CRIT_PCT}'; bash -s" <<'REMOTE'
set -uo pipefail

PASS=0; FAIL=0; SKIP=0; WARN=0
pass() { PASS=$((PASS+1)); echo "PASS $*"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL $*"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP $*"; }
warn() { WARN=$((WARN+1)); echo "WARN $*"; }
check() { if eval "$1"; then pass "$2"; else fail "$2"; fi; }

echo "=== remote node $(hostname) ==="

# [1] Node Ready
echo "[1] Node Ready"
node_json=$(kubectl get nodes -o json 2>/dev/null || echo '{}')
node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
check "[[ \"${node_count}\" -ge 1 ]]" "at least one node present"
ready_count=0
not_ready=0
while read -r name ready; do
  [[ -z "$name" ]] && continue
  if [[ "$ready" == "True" ]]; then
    ready_count=$((ready_count + 1))
    pass "node ${name} Ready=True"
  else
    not_ready=$((not_ready + 1))
    fail "node ${name} Ready=${ready}"
  fi
done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' 2>/dev/null)
echo "EVIDENCE node_ready_count=${ready_count} not_ready=${not_ready}"

# [2] metrics-server
echo "[2] metrics-server"
if kubectl -n kube-system get deploy metrics-server >/dev/null 2>&1 || \
   kubectl -n kube-system get apiService v1beta1.metrics.k8s.io >/dev/null 2>&1 || \
   kubectl get apiservice v1beta1.metrics.k8s.io >/dev/null 2>&1; then
  pass "metrics-server API/deploy present"
else
  # K3s often exposes metrics via bundled metrics-server pod
  if kubectl -n kube-system get pods -l k8s-app=metrics-server --no-headers 2>/dev/null | grep -q Running; then
    pass "metrics-server pod Running in kube-system"
  else
    fail "metrics-server not found"
  fi
fi

ms_ready=$(kubectl -n kube-system get pods -l k8s-app=metrics-server -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo Missing)
if [[ "$ms_ready" == "Running" ]]; then
  pass "metrics-server pod phase=Running"
else
  # try alternate labels
  if kubectl -n kube-system get pods --no-headers 2>/dev/null | grep -qi metrics-server; then
    pass "metrics-server-like pod present in kube-system"
  else
    warn "metrics-server pod phase=${ms_ready}"
  fi
fi

# [3] kubectl top nodes (CPU/memory saturation)
echo "[3] Node CPU/memory via kubectl top"
if kubectl top nodes --no-headers >/tmp/obs-top-nodes 2>/dev/null; then
  pass "kubectl top nodes available"
  cat /tmp/obs-top-nodes
  while read -r name cpu_raw cpu_pct mem_raw mem_pct rest; do
    [[ -z "$name" ]] && continue
    # cpu_pct like 12% ; mem_pct like 69%
    c="${cpu_pct%%%}"
    m="${mem_pct%%%}"
    # strip non-digits
    c=$(echo "$c" | tr -dc '0-9')
    m=$(echo "$m" | tr -dc '0-9')
    echo "EVIDENCE node=${name} cpu_pct=${c:-0} mem_pct=${m:-0} cpu_raw=${cpu_raw} mem_raw=${mem_raw}"
    if [[ -n "$m" ]]; then
      if (( m >= MEM_CRIT_PCT )); then
        fail "node ${name} memory ${m}% >= critical ${MEM_CRIT_PCT}%"
      elif (( m >= MEM_WARN_PCT )); then
        warn "node ${name} memory ${m}% >= warn ${MEM_WARN_PCT}%"
      else
        pass "node ${name} memory ${m}% below warn ${MEM_WARN_PCT}%"
      fi
    else
      skip "node ${name} memory percent unparseable"
    fi
    if [[ -n "$c" ]]; then
      if (( c >= CPU_CRIT_PCT )); then
        fail "node ${name} CPU ${c}% >= critical ${CPU_CRIT_PCT}%"
      elif (( c >= CPU_WARN_PCT )); then
        warn "node ${name} CPU ${c}% >= warn ${CPU_WARN_PCT}%"
      else
        pass "node ${name} CPU ${c}% below warn ${CPU_WARN_PCT}%"
      fi
    else
      skip "node ${name} CPU percent unparseable"
    fi
  done < /tmp/obs-top-nodes
else
  fail "kubectl top nodes failed (metrics-server unavailable)"
fi

# [4] Pod CPU/memory for demo apps
echo "[4] Pod CPU/memory (demo apps)"
if kubectl top pods -A --no-headers >/tmp/obs-top-pods 2>/dev/null; then
  pass "kubectl top pods available"
  grep -E 'ai-doc-assistant|booknbook|platform-smoke' /tmp/obs-top-pods || true
  app_lines=$(grep -E 'apps-ai-doc-assistant-homelab|apps-booknbook-homelab' /tmp/obs-top-pods | wc -l | tr -d ' ')
  if [[ "${app_lines}" -ge 1 ]]; then
    pass "demo app pod metrics present (lines=${app_lines})"
  else
    warn "no demo app rows in kubectl top pods"
  fi
else
  fail "kubectl top pods failed"
fi

# [5] Argo applications
echo "[5] Argo CD applications"
apps=(ai-doc-assistant booknbook)
namespaces=(apps-ai-doc-assistant-homelab apps-booknbook-homelab)
argocd_apps=(ai-doc-assistant-homelab booknbook-homelab)

for i in 0 1; do
  app="${apps[$i]}"
  ns="${namespaces[$i]}"
  argo="${argocd_apps[$i]}"
  sync=$(kubectl -n argocd get application "$argo" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo Missing)
  health=$(kubectl -n argocd get application "$argo" -o jsonpath='{.status.health.status}' 2>/dev/null || echo Missing)
  echo "EVIDENCE argo=${argo} sync=${sync} health=${health}"
  check "[[ \"$sync\" == Synced && \"$health\" == Healthy ]]" "$argo Synced/Healthy"

  # Pod Ready + restarts
  ready=$(kubectl -n "$ns" get pod -l "app.kubernetes.io/name=$app" -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo false)
  restarts=$(kubectl -n "$ns" get pod -l "app.kubernetes.io/name=$app" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo 999)
  phase=$(kubectl -n "$ns" get pod -l "app.kubernetes.io/name=$app" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo Missing)
  echo "EVIDENCE app=${app} phase=${phase} ready=${ready} restarts=${restarts}"
  check "[[ \"$ready\" == true ]]" "$app pod Ready"
  check "[[ \"$restarts\" == 0 ]]" "$app restartCount=0 (baseline)"

  # Desired vs ready replicas
  desired=$(kubectl -n "$ns" get deploy "$app" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
  ready_r=$(kubectl -n "$ns" get deploy "$app" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  check "[[ \"${desired:-0}\" == \"${ready_r:-0}\" && \"${desired:-0}\" -gt 0 ]]" "$app replicas desired=${desired} ready=${ready_r}"

  # No unexpected HPA for demo apps (homelab values disable autoscaling)
  if kubectl -n "$ns" get hpa "$app" >/dev/null 2>&1; then
    hmin=$(kubectl -n "$ns" get hpa "$app" -o jsonpath='{.spec.minReplicas}' 2>/dev/null || echo '?')
    hmax=$(kubectl -n "$ns" get hpa "$app" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || echo '?')
    cur=$(kubectl -n "$ns" get hpa "$app" -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo '?')
    warn "$app HPA present min=${hmin} max=${hmax} current=${cur} (homelab demos usually disable HPA)"
    # Fail only if current replicas drifted far from desired deploy
    if [[ "$cur" =~ ^[0-9]+$ && "$desired" =~ ^[0-9]+$ && "$cur" != "$desired" ]]; then
      fail "$app HPA currentReplicas=${cur} != deploy desired=${desired}"
    fi
  else
    pass "$app no HPA (expected for Homelab demo)"
  fi
done

# Optional platform-smoke if present
if kubectl -n argocd get application platform-smoke-homelab >/dev/null 2>&1; then
  ps=$(kubectl -n argocd get application platform-smoke-homelab -o jsonpath='{.status.sync.status}')
  ph=$(kubectl -n argocd get application platform-smoke-homelab -o jsonpath='{.status.health.status}')
  check "[[ \"$ps\" == Synced && \"$ph\" == Healthy ]]" "platform-smoke-homelab Synced/Healthy"
else
  skip "platform-smoke-homelab Application not present"
fi

# [6] CrashLoopBackOff / ImagePullBackOff
echo "[6] Bad pod phases (CrashLoop/ImagePull)"
bad=$(kubectl get pods -A --no-headers 2>/dev/null | grep -E 'CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerError' || true)
if [[ -z "$bad" ]]; then
  pass "no CrashLoopBackOff/ImagePullBackOff/ErrImagePull cluster-wide"
else
  echo "$bad" | head -20
  fail "bad pod states present (see above)"
fi

# [7] Ingress health/readiness
echo "[7] Ingress /healthz /readyz"
for host in ai-doc-assistant.homelab.local booknbook.homelab.local; do
  for path in /healthz /readyz; do
    code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' -H "Host: ${host}" "http://127.0.0.1${path}" 2>/dev/null || echo 000)
    echo "EVIDENCE ingress host=${host} path=${path} code=${code}"
    check "[[ \"$code\" == 200 ]]" "ingress ${host}${path}=${code}"
  done
done

# [8] Kyverno policy reports
echo "[8] Kyverno policy reports"
if kubectl get crd policyreports.wgpolicyk8s.io >/dev/null 2>&1; then
  pass "PolicyReport CRD present"
  for ns in apps-ai-doc-assistant-homelab apps-booknbook-homelab; do
    if kubectl -n "$ns" get policyreport >/dev/null 2>&1; then
      # sum fail/error if columns exist
      fails=$(kubectl -n "$ns" get policyreport -o jsonpath='{range .items[*]}{.summary.fail}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END {print s+0}')
      errs=$(kubectl -n "$ns" get policyreport -o jsonpath='{range .items[*]}{.summary.error}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END {print s+0}')
      echo "EVIDENCE ns=${ns} policyreport_fail=${fails} error=${errs}"
      if [[ "${fails}" -eq 0 && "${errs}" -eq 0 ]]; then
        pass "${ns} PolicyReport fail=0 error=0"
      else
        warn "${ns} PolicyReport fail=${fails} error=${errs} (Audit mode may still report)"
      fi
    else
      skip "${ns} no PolicyReport objects"
    fi
  done
else
  skip "PolicyReport CRD not installed"
fi

# [9] No public endpoint exposure (private Homelab)
echo "[9] Public exposure guards"
# Ingress hosts should be *.homelab.local or *.local
bad_hosts=$(kubectl get ingress -A -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\n"}{end}{end}' 2>/dev/null \
  | grep -vE '\.homelab\.local$|\.local$|^$' || true)
if [[ -z "$bad_hosts" ]]; then
  pass "all Ingress hosts are private *.homelab.local / *.local"
else
  echo "$bad_hosts"
  fail "non-private Ingress hosts present"
fi

# No LoadBalancer EXTERNAL-IP that looks public (non-empty and not <pending>/<none>)
lb_pub=$(kubectl get svc -A --no-headers 2>/dev/null \
  | awk '$2=="LoadBalancer" && $5!="<none>" && $5!="<pending>" && $5!="" {print}' \
  | grep -vE '192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.' || true)
if [[ -z "$lb_pub" ]]; then
  pass "no public LoadBalancer EXTERNAL-IP observed"
else
  echo "$lb_pub"
  fail "possible public LoadBalancer EXTERNAL-IP"
fi

# Confirm no kube-prometheus-stack / heavy stack (safety evidence)
echo "[10] Heavy monitoring stack absence (Homelab boundary)"
heavy=$(kubectl get ns 2>/dev/null | grep -E 'monitoring|observability|prometheus' || true)
if kubectl get pods -A --no-headers 2>/dev/null | grep -qiE 'kube-prometheus|prometheus-operator|loki-|tempo-|grafana'; then
  # metrics-server alone is fine; flag full stack
  if kubectl get pods -A --no-headers 2>/dev/null | grep -qiE 'kube-prometheus|prometheus-operator|loki-|tempo-'; then
    fail "heavy monitoring pods present (prometheus-operator/loki/tempo)"
  else
    warn "grafana-like pods present; confirm not full stack"
  fi
else
  pass "no kube-prometheus-stack/Loki/Tempo pods detected"
fi
if [[ -n "$heavy" ]]; then
  echo "EVIDENCE namespaces=$heavy"
  warn "monitoring-related namespaces exist (inspect if intentional)"
else
  pass "no dedicated monitoring/observability namespace"
fi

echo "REMOTE_SUMMARY PASS=$PASS FAIL=$FAIL SKIP=$SKIP WARN=$WARN"
[[ "$FAIL" == 0 ]]
REMOTE
)" || REMOTE_RC=$?
REMOTE_RC="${REMOTE_RC:-0}"

# Replay remote lines into local counters for the summary.
while IFS= read -r line; do
  case "$line" in
    PASS\ *) ok "${line#PASS }" ;;
    FAIL\ *) fail "${line#FAIL }" ;;
    SKIP\ *) skip "${line#SKIP }" ;;
    WARN\ *) warn "${line#WARN }" ;;
    EVIDENCE\ *|===*|\[*\]*|--*|REMOTE_SUMMARY*) log "  · ${line}" ;;
    *)
      # top output tables etc.
      if [[ -n "$line" ]]; then
        log "  · ${line}"
      fi
      ;;
  esac
done <<< "$REMOTE_OUT"

# ---------------------------------------------------------------------------
log ""
log "============================================================"
log "Homelab observability: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP  WARN=$WARN"
log "============================================================"
for line in "${REPORT[@]}"; do
  log "$line"
done
log ""
log "Notes:"
log "  - metrics-server only on Homelab K3s (no Prometheus/Grafana in cluster)"
log "  - Prometheus/Grafana remain Docker Compose Lab services"
log "  - WARN does not fail the run; FAIL does"
log "  - design-only alerts: infra/platform/observability/alerts/"
log "============================================================"

if [[ "$FAIL" -gt 0 || "$REMOTE_RC" -ne 0 ]]; then
  exit 1
fi
exit 0
