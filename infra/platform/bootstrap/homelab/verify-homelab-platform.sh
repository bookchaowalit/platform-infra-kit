#!/usr/bin/env bash
# Homelab platform operations baseline for the two live portfolio apps.
# Read-only checks; does not mutate workloads or cloud resources.
set -euo pipefail

K3S_HOST="${K3S_HOST:-192.168.152.114}"
K3S_USER="${K3S_USER:-soloadmin}"
REMOTE_KUBECONFIG="${REMOTE_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

ssh -o BatchMode=yes -o ConnectTimeout=15 "${K3S_USER}@${K3S_HOST}" \
  "export KUBECONFIG='${REMOTE_KUBECONFIG}'; bash -s" <<'REMOTE'
set -euo pipefail

PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); echo "PASS $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $*" >&2; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP $*"; }
check() { if eval "$1"; then pass "$2"; else fail "$2"; fi; }

echo "=== Homelab platform operations baseline ==="
echo "node=$(hostname)"

apps=(ai-doc-assistant booknbook)
namespaces=(apps-ai-doc-assistant-homelab apps-booknbook-homelab)
argocd_apps=(ai-doc-assistant-homelab booknbook-homelab)

for i in 0 1; do
  app="${apps[$i]}"
  ns="${namespaces[$i]}"
  argo="${argocd_apps[$i]}"
  sync=$(kubectl -n argocd get application "$argo" -o jsonpath='{.status.sync.status}')
  health=$(kubectl -n argocd get application "$argo" -o jsonpath='{.status.health.status}')
  check "[[ \"$sync\" == Synced && \"$health\" == Healthy ]]" "$argo Argo Synced/Healthy"

  image=$(kubectl -n "$ns" get deploy "$app" -o jsonpath='{.spec.template.spec.containers[0].image}')
  check "[[ \"$image\" =~ :git-[0-9a-f]{7,40}$ ]]" "$app immutable image"
  check "[[ \"$image\" != *:latest* ]]" "$app does not use :latest"

  ready=$(kubectl -n "$ns" get pod -l "app.kubernetes.io/name=$app" -o jsonpath='{.items[0].status.containerStatuses[0].ready}')
  restarts=$(kubectl -n "$ns" get pod -l "app.kubernetes.io/name=$app" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
  check "[[ \"$ready\" == true ]]" "$app pod Ready"
  check "[[ \"$restarts\" == 0 ]]" "$app restartCount=0"

  np=$(kubectl -n "$ns" get networkpolicy "$app" -o name 2>/dev/null || true)
  check "[[ -n \"$np\" ]]" "$app NetworkPolicy present"

  echo "-- $app resources --"
  kubectl -n "$ns" get deploy "$app" -o custom-columns=APP:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,CPU_REQ:.spec.template.spec.containers[0].resources.requests.cpu,MEM_REQ:.spec.template.spec.containers[0].resources.requests.memory,CPU_LIMIT:.spec.template.spec.containers[0].resources.limits.cpu,MEM_LIMIT:.spec.template.spec.containers[0].resources.limits.memory
done

echo "-- ingress smoke --"
for spec in \
  "ai-doc-assistant.homelab.local /healthz" \
  "ai-doc-assistant.homelab.local /readyz" \
  "ai-doc-assistant.homelab.local /" \
  "booknbook.homelab.local /healthz" \
  "booknbook.homelab.local /readyz" \
  "booknbook.homelab.local /" \
  "booknbook.homelab.local /th"; do
  host="${spec%% *}"
  path="${spec#* }"
  code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: $host" "http://127.0.0.1$path")
  if [[ "$path" == "/" && "$host" == "booknbook.homelab.local" ]]; then
    check "[[ \"$code\" == 307 ]]" "$host $path=307 locale redirect"
  else
    check "[[ \"$code\" == 200 ]]" "$host $path=200"
  fi
done

echo "-- resource usage --"
if kubectl top nodes >/tmp/solo-homelab-top-nodes 2>/dev/null; then
  pass "metrics-server node usage available"
  cat /tmp/solo-homelab-top-nodes
  kubectl top pods -A --no-headers | grep -E 'ai-doc-assistant|booknbook' || true
else
  skip "metrics-server node usage unavailable"
fi

echo "-- platform summary --"
kubectl get nodes -o wide
kubectl -n argocd get applications ai-doc-assistant-homelab booknbook-homelab -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision

echo "Homelab platform baseline: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ "$FAIL" == 0 ]]
REMOTE
