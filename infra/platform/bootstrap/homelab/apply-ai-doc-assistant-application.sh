#!/usr/bin/env bash
# Apply the Homelab Argo Application for ai-doc-assistant with an immutable tag.
# Usage: IMAGE_TAG=git-<fullsha> ./apply-ai-doc-assistant-application.sh
# Never uses :latest. Does not print secrets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
APP_FILE="${ROOT}/infra/platform/gitops/homelab/applications/ai-doc-assistant-homelab.yaml"
PROJECT_FILE="${ROOT}/infra/platform/gitops/homelab/argocd/solo-empire-apps-project.yaml"
POLICY_FILE="${ROOT}/infra/platform/policies/kyverno/approved-registries.yaml"
K3S_HOST="${K3S_HOST:-192.168.152.114}"
K3S_USER="${K3S_USER:-soloadmin}"
IMAGE_TAG="${IMAGE_TAG:-}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-registry.homelab.local:5000/solo-empire/ai-doc-assistant}"

if [[ -z "${IMAGE_TAG}" ]]; then
  echo "ERROR: set IMAGE_TAG=git-<full-git-sha>" >&2
  exit 1
fi
if [[ "${IMAGE_TAG}" == "latest" || "${IMAGE_TAG}" == "git-pending" ]]; then
  echo "ERROR: refuse non-immutable tag ${IMAGE_TAG}" >&2
  exit 1
fi
if [[ ! "${IMAGE_TAG}" =~ ^git-[0-9a-f]{7,40}$ ]]; then
  echo "ERROR: IMAGE_TAG must look like git-<hexsha>" >&2
  exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT
# Render Application with concrete immutable tag (does not modify git working tree)
sed \
  -e "s|value: git-pending|value: ${IMAGE_TAG}|g" \
  -e "s|value: registry.homelab.local:5000/solo-empire/ai-doc-assistant|value: ${IMAGE_REPOSITORY}|g" \
  "${APP_FILE}" >"${TMP}"

# Apply AppProject + policy + Application via remote kubectl
ssh -o BatchMode=yes "${K3S_USER}@${K3S_HOST}" "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; mkdir -p /tmp/solo-gitops"
scp -o BatchMode=yes "${PROJECT_FILE}" "${K3S_USER}@${K3S_HOST}:/tmp/solo-gitops/project.yaml"
scp -o BatchMode=yes "${POLICY_FILE}" "${K3S_USER}@${K3S_HOST}:/tmp/solo-gitops/approved-registries.yaml"
scp -o BatchMode=yes "${TMP}" "${K3S_USER}@${K3S_HOST}:/tmp/solo-gitops/ai-doc-assistant-homelab.yaml"

ssh -o BatchMode=yes "${K3S_USER}@${K3S_HOST}" 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
set -euo pipefail
kubectl apply -f /tmp/solo-gitops/project.yaml
kubectl apply -f /tmp/solo-gitops/approved-registries.yaml
kubectl apply -f /tmp/solo-gitops/ai-doc-assistant-homelab.yaml
rm -rf /tmp/solo-gitops
echo "Application applied; waiting for Synced/Healthy..."
for i in $(seq 1 48); do
  SYNC=$(kubectl -n argocd get application ai-doc-assistant-homelab -o jsonpath="{.status.sync.status}" 2>/dev/null || echo Unknown)
  HEALTH=$(kubectl -n argocd get application ai-doc-assistant-homelab -o jsonpath="{.status.health.status}" 2>/dev/null || echo Unknown)
  echo "  attempt $i: sync=$SYNC health=$HEALTH"
  if [[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]]; then
    echo APP_SYNCED_HEALTHY
    kubectl -n argocd get application ai-doc-assistant-homelab -o wide
    kubectl -n apps-ai-doc-assistant-homelab get deploy,pod,svc,ingress
    exit 0
  fi
  sleep 5
done
kubectl -n argocd get application ai-doc-assistant-homelab -o yaml | head -120
exit 1
'

echo "apply-ai-doc-assistant-application: done (tag=${IMAGE_TAG})"
