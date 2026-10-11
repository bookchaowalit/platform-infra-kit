#!/usr/bin/env bash
# Verify K3s can pull an immutable image from the private Fedora registry.
set -euo pipefail

K3S_HOST="${K3S_HOST:-192.168.152.114}"
K3S_USER="${K3S_USER:-soloadmin}"
REGISTRY_HOST="${REGISTRY_HOST:-registry.homelab.local}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
TEST_IMAGE="${TEST_IMAGE:-}"

if [[ -z "${TEST_IMAGE}" ]]; then
  echo "ERROR: set TEST_IMAGE to an immutable tag already in the registry" >&2
  exit 1
fi

ssh -o BatchMode=yes "${K3S_USER}@${K3S_HOST}" "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
set -euo pipefail
NS=registry-pull-test
kubectl delete ns \$NS --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl create ns \$NS
kubectl -n \$NS delete pod registry-pull-test --ignore-not-found >/dev/null 2>&1 || true
kubectl -n \$NS run registry-pull-test --image='${TEST_IMAGE}' --restart=Never --command -- /bin/true
# busybox true exits; for app images use sleep
kubectl -n \$NS delete pod registry-pull-test --ignore-not-found >/dev/null 2>&1 || true
kubectl -n \$NS run registry-pull-test --image='${TEST_IMAGE}' --restart=Never --command -- sleep 30
for i in \$(seq 1 36); do
  PHASE=\$(kubectl -n \$NS get pod registry-pull-test -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)
  echo \"  pull attempt \$i phase=\$PHASE\"
  if [[ \"\$PHASE\" == \"Running\" || \"\$PHASE\" == \"Succeeded\" ]]; then
    echo PULL_OK
    kubectl -n \$NS delete pod registry-pull-test --ignore-not-found >/dev/null
    kubectl delete ns \$NS --ignore-not-found >/dev/null
    exit 0
  fi
  if [[ \"\$PHASE\" == \"Failed\" ]]; then
    kubectl -n \$NS describe pod registry-pull-test | tail -40
    exit 1
  fi
  sleep 5
done
kubectl -n \$NS describe pod registry-pull-test | tail -40
exit 1
"
