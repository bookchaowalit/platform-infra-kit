#!/usr/bin/env bash
# Read-only data readiness gate for the Homelab ai-doc-assistant demo.
# This intentionally proves that the deployment is ephemeral; it does not
# install a database, vector store, object store, PVC, or backup system.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
VALUES_FILE="${ROOT_DIR}/infra/platform/helm/solo-app/homelab/ai-doc-assistant.yaml"
K3S_HOST="${K3S_HOST:-192.168.152.114}"
K3S_USER="${K3S_USER:-soloadmin}"
REMOTE_KUBECONFIG="${REMOTE_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

PASS=0
FAIL=0
check_local() {
  if "$@"; then
    PASS=$((PASS + 1))
    echo "PASS $*"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL $*" >&2
  fi
}

echo "=== ai-doc-assistant data readiness ==="
echo "scope=homelab demo; no data-plane changes"

check_local test -f "$VALUES_FILE"
check_local grep -q '^    SOLO_DATA_CONTRACT: demo-ephemeral$' "$VALUES_FILE"
check_local grep -q '^    SOLO_DATA_DURABILITY: ephemeral$' "$VALUES_FILE"
check_local grep -q '^    SOLO_VECTOR_STORE: chroma-emptyDir$' "$VALUES_FILE"
check_local grep -q '^    SOLO_OBJECT_STORAGE: none$' "$VALUES_FILE"
check_local grep -q '^[[:space:]]*emptyDir: {}' "$VALUES_FILE"
check_local bash -c '! grep -q "persistentVolumeClaim" "$1"' _ "$VALUES_FILE"

ssh -o BatchMode=yes -o ConnectTimeout=15 "${K3S_USER}@${K3S_HOST}" \
  "export KUBECONFIG='${REMOTE_KUBECONFIG}'; bash -s" <<'REMOTE'
set -euo pipefail

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $*" >&2; }
check() { if eval "$1"; then pass "$2"; else fail "$2"; fi; }

NS=apps-ai-doc-assistant-homelab
APP=ai-doc-assistant
ARGO=ai-doc-assistant-homelab

sync=$(kubectl -n argocd get application "$ARGO" -o jsonpath='{.status.sync.status}')
health=$(kubectl -n argocd get application "$ARGO" -o jsonpath='{.status.health.status}')
check "[[ \"$sync\" == Synced && \"$health\" == Healthy ]]" "Argo Synced/Healthy"

replicas=$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.replicas}')
ready=$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.status.readyReplicas}')
check "[[ \"$replicas\" == 1 ]]" "single replica is explicit"
check "[[ \"$ready\" == 1 ]]" "one replica Ready"

for volume in uploads chroma; do
  empty_dir=$(kubectl -n "$NS" get deploy "$APP" \
    -o jsonpath="{.spec.template.spec.volumes[?(@.name=='${volume}')].emptyDir}")
  check "[[ -n \"$empty_dir\" ]]" "$volume uses emptyDir"
done

pvc_count=$(kubectl -n "$NS" get pvc --no-headers 2>/dev/null | awk 'NF { count++ } END { print count + 0 }')
check "[[ \"$pvc_count\" == 0 ]]" "no PVC claims durability"

hpa_count=$(kubectl -n "$NS" get hpa --no-headers 2>/dev/null | awk 'NF { count++ } END { print count + 0 }')
check "[[ \"$hpa_count\" == 0 ]]" "no HPA claims scalable durable state"

services=$(kubectl -n "$NS" get svc -o jsonpath='{range .items[*]}{.metadata.name}{"\\n"}{end}')
for forbidden in postgres postgresql redis qdrant chroma minio; do
  check "! grep -Eiq '(^|[-])${forbidden}($|[-])' <<< \"$services\"" "no in-namespace $forbidden service"
done

echo "remote checks: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
REMOTE

echo "DATA_READINESS=DEMO_ONLY"
echo "PASS=$PASS FAIL=$FAIL"
echo "No durable data service is installed; staging/production promotion remains blocked."
[[ "$FAIL" == 0 ]]
