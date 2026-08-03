#!/usr/bin/env bash
set -euo pipefail

BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
export PATH="$BIN_DIR:$PATH"

command -v kubectl >/dev/null 2>&1 || { echo 'kubectl is required' >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo 'helm is required' >&2; exit 1; }
kubectl cluster-info >/dev/null

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo add kyverno https://kyverno.github.io/kyverno >/dev/null
helm repo add external-secrets https://charts.external-secrets.io >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
helm repo update >/dev/null

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --set server.service.type=ClusterIP \
  --wait --timeout 10m

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --wait --timeout 10m

helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --wait --timeout 10m

helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --set installCRDs=true \
  --wait --timeout 10m

if kubectl -n kube-system get deployment metrics-server >/dev/null 2>&1; then
  echo 'metrics-server already exists in K3s; keeping the bundled deployment'
else
  helm upgrade --install metrics-server metrics-server/metrics-server \
    --namespace kube-system \
    --set 'args[0]=--kubelet-insecure-tls' \
    --wait --timeout 10m
fi

if [[ "${INSTALL_OBSERVABILITY:-false}" == "true" ]]; then
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
  helm repo update >/dev/null
  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace \
    --set grafana.service.type=ClusterIP \
    --wait --timeout 15m
fi

echo 'Platform components installed. No business application was deployed.'
kubectl get pods -A
