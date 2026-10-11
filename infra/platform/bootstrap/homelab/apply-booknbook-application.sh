#!/usr/bin/env bash
# Apply the Homelab Argo Application for booknbook with an immutable tag.
# Usage: IMAGE_TAG=git-<fullsha> ./apply-booknbook-application.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
APP_FILE="${ROOT}/infra/platform/gitops/homelab/applications/booknbook-homelab.yaml"
PROJECT_FILE="${ROOT}/infra/platform/gitops/homelab/argocd/solo-empire-apps-project.yaml"
POLICY_FILE="${ROOT}/infra/platform/policies/kyverno/approved-registries.yaml"
K3S_HOST="${K3S_HOST:-192.168.152.114}"
K3S_USER="${K3S_USER:-soloadmin}"
IMAGE_TAG="${IMAGE_TAG:-}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-registry.homelab.local:5000/solo-empire/booknbook}"

if [[ -z "${IMAGE_TAG}" || ! "${IMAGE_TAG}" =~ ^git-[0-9a-f]{7,40}$ ]]; then
  echo "ERROR: set IMAGE_TAG=git-<7..40 hex chars>" >&2
  exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT
sed \
  -e "s|value: git-pending|value: ${IMAGE_TAG}|g" \
  -e "s|value: registry.homelab.local:5000/solo-empire/booknbook|value: ${IMAGE_REPOSITORY}|g" \
  "${APP_FILE}" >"${TMP}"

ssh -o BatchMode=yes "${K3S_USER}@${K3S_HOST}" \
  "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; mkdir -p /tmp/solo-gitops"
scp -o BatchMode=yes "${PROJECT_FILE}" "${K3S_USER}@${K3S_HOST}:/tmp/solo-gitops/project.yaml"
scp -o BatchMode=yes "${POLICY_FILE}" "${K3S_USER}@${K3S_HOST}:/tmp/solo-gitops/approved-registries.yaml"
scp -o BatchMode=yes "${TMP}" "${K3S_USER}@${K3S_HOST}:/tmp/solo-gitops/booknbook-homelab.yaml"

ssh -o BatchMode=yes "${K3S_USER}@${K3S_HOST}" 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
set -euo pipefail
kubectl apply -f /tmp/solo-gitops/project.yaml
kubectl apply -f /tmp/solo-gitops/approved-registries.yaml
kubectl apply -f /tmp/solo-gitops/booknbook-homelab.yaml
rm -rf /tmp/solo-gitops
echo BOOKNBOOK_APPLICATION_APPLIED
'

echo "apply-booknbook-application: done (tag=${IMAGE_TAG})"
