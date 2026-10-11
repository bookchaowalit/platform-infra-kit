#!/usr/bin/env bash
# Business smoke test for booknbook on Homelab K3s.
# Non-production only; does not mutate workloads.
set -euo pipefail

K3S_HOST="${K3S_HOST:-192.168.152.114}"
K3S_USER="${K3S_USER:-soloadmin}"
REMOTE_KUBECONFIG="${REMOTE_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NS="${NS:-apps-booknbook-homelab}"
APP="${APP:-booknbook}"
ARGO_APP="${ARGO_APP:-booknbook-homelab}"
HOST="${HOST:-booknbook.homelab.local}"

ssh -o BatchMode=yes -o ConnectTimeout=15 "${K3S_USER}@${K3S_HOST}" \
  "export KUBECONFIG='${REMOTE_KUBECONFIG}'; NS='${NS}' APP='${APP}' ARGO_APP='${ARGO_APP}' HOST='${HOST}' bash -s" <<'REMOTE'
set -euo pipefail
NS="${NS}"
APP="${APP}"
ARGO_APP="${ARGO_APP}"
HOST="${HOST}"
BASE=http://127.0.0.1
PASS=0

pass() { PASS=$((PASS + 1)); echo "PASS $*"; }
check() { if eval "$1"; then pass "$2"; else echo "FAIL $2" >&2; exit 1; fi; }

sync=$(kubectl -n argocd get application "$ARGO_APP" -o jsonpath='{.status.sync.status}')
health=$(kubectl -n argocd get application "$ARGO_APP" -o jsonpath='{.status.health.status}')
check "[[ \"$sync\" == Synced && \"$health\" == Healthy ]]" "Argo Synced/Healthy"

image=$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}')
check "[[ \"$image\" =~ :git-[0-9a-f]{7,40}$ ]]" "immutable image tag"

ready=$(kubectl -n "$NS" get pod -l "app.kubernetes.io/name=$APP" -o jsonpath='{.items[0].status.containerStatuses[0].ready}')
restarts=$(kubectl -n "$NS" get pod -l "app.kubernetes.io/name=$APP" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
check "[[ \"$ready\" == true && \"$restarts\" == 0 ]]" "pod Ready with zero restarts"

for path in /healthz /readyz; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: $HOST" "$BASE$path")
  check "[[ \"$code\" == 200 ]]" "${path}=200"
done

headers=$(curl -sS -D - -o /dev/null -H "Host: $HOST" "$BASE/")
check "grep -qi 'HTTP/.* 307' <<<\"$headers\"" "homepage redirects 307"
check "grep -qi 'location: /th' <<<\"$headers\"" "homepage redirects to /th"

for path in /th /en /ja; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: $HOST" "$BASE$path")
  check "[[ \"$code\" == 200 ]]" "${path}=200"
done

asset=$(curl -sS -H "Host: $HOST" "$BASE/th" | grep -oE '/_next/static/[^" ]+\.js' | head -1)
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: $HOST" "$BASE$asset")
check "[[ -n \"$asset\" && \"$code\" == 200 ]]" "Next.js static asset=200"

echo "booknbook Homelab smoke: PASS=$PASS FAIL=0"
echo "image=$image"
REMOTE
