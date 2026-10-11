#!/usr/bin/env bash
# End-to-end Homelab onboard for ai-doc-assistant after Fedora SSH works.
# Phases: registry install -> k3s trust -> build/push -> apply Argo app.
# Never prints passwords. Never uses :latest.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
BOOT="${ROOT}/infra/platform/bootstrap/homelab"
FEDORA_HOST="${FEDORA_HOST:-192.168.152.12}"
FEDORA_USER="${FEDORA_USER:-bookchaowalit}"

echo "== Phase 0: SSH preflight =="
ssh -o BatchMode=yes -o ConnectTimeout=10 "${FEDORA_USER}@${FEDORA_HOST}" 'echo SSH_OK; hostname; docker --version'

echo "== Phase 1: Install registry on Fedora =="
scp -o BatchMode=yes "${BOOT}/install-registry-on-fedora.sh" \
  "${FEDORA_USER}@${FEDORA_HOST}:/tmp/install-registry-on-fedora.sh"
ssh -o BatchMode=yes "${FEDORA_USER}@${FEDORA_HOST}" \
  'sudo bash /tmp/install-registry-on-fedora.sh'

echo "== Phase 2: Configure K3s + operator trust =="
bash "${BOOT}/configure-k3s-registry-trust.sh"

echo "== Phase 3: Build + push immutable image =="
# shellcheck disable=SC1091
eval "$(bash "${BOOT}/build-push-ai-doc-assistant.sh" | tee /dev/stderr | grep -E '^(IMAGE_REPOSITORY|IMAGE_TAG|FULL_IMAGE)=')"
: "${IMAGE_TAG:?missing IMAGE_TAG}"
: "${FULL_IMAGE:?missing FULL_IMAGE}"

echo "== Phase 3b: Verify K3s pull =="
TEST_IMAGE="${FULL_IMAGE}" bash "${BOOT}/verify-registry-pull.sh"

echo "== Phase 4: Apply Argo Application =="
IMAGE_TAG="${IMAGE_TAG}" IMAGE_REPOSITORY="${IMAGE_REPOSITORY}" \
  bash "${BOOT}/apply-ai-doc-assistant-application.sh"

echo "== Phase 4b: Smoke health/ingress =="
ssh -o BatchMode=yes soloadmin@192.168.152.114 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
set -euo pipefail
kubectl -n apps-ai-doc-assistant-homelab get deploy,pod,svc,ingress
# service probe
kubectl -n apps-ai-doc-assistant-homelab delete pod smoke-health --ignore-not-found >/dev/null 2>&1 || true
kubectl -n apps-ai-doc-assistant-homelab run smoke-health --rm -i --restart=Never \
  --image=public.ecr.aws/docker/library/busybox:1.36.1 --command -- \
  wget -qO- http://ai-doc-assistant.apps-ai-doc-assistant-homelab.svc.cluster.local/healthz
echo
kubectl -n apps-ai-doc-assistant-homelab run smoke-ready --rm -i --restart=Never \
  --image=public.ecr.aws/docker/library/busybox:1.36.1 --command -- \
  wget -qO- http://ai-doc-assistant.apps-ai-doc-assistant-homelab.svc.cluster.local/readyz
echo
curl -fsS -H "Host: ai-doc-assistant.homelab.local" http://127.0.0.1/healthz; echo
curl -fsS -H "Host: ai-doc-assistant.homelab.local" http://127.0.0.1/readyz; echo
IMG=$(kubectl -n apps-ai-doc-assistant-homelab get deploy ai-doc-assistant -o jsonpath="{.spec.template.spec.containers[0].image}")
echo "image=$IMG"
echo "$IMG" | grep -q ":git-" || { echo "ERROR: image tag not immutable git-SHA"; exit 1; }
echo "$IMG" | grep -q ":latest" && { echo "ERROR: latest tag forbidden"; exit 1; } || true
kubectl -n apps-ai-doc-assistant-homelab get policyreport -o custom-columns=KIND:.scope.kind,FAIL:.summary.fail,ERROR:.summary.error || true
'

echo "bootstrap-ai-doc-assistant-homelab: complete"
echo "  IMAGE_TAG=${IMAGE_TAG}"
echo "  Application: ai-doc-assistant-homelab"
