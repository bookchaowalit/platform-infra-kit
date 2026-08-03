#!/usr/bin/env bash
set -euo pipefail

BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
export PATH="$BIN_DIR:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-solo-dev}"
HTTP_PORT="${K3D_HTTP_PORT:-18080}"
HTTPS_PORT="${K3D_HTTPS_PORT:-18443}"
API_PORT="${K3D_API_PORT:-6550}"
# Disposable local registry (set CREATE_REGISTRY=false to skip)
CREATE_REGISTRY="${CREATE_REGISTRY:-true}"
REGISTRY_NAME="${REGISTRY_NAME:-solo-registry}"
REGISTRY_HOST_PORT="${REGISTRY_HOST_PORT:-5111}"

command -v docker >/dev/null 2>&1 || { echo 'Docker is required' >&2; exit 1; }
command -v k3d >/dev/null 2>&1 || { echo 'Run install-tools.sh first' >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo 'Run install-tools.sh first' >&2; exit 1; }

REG_ARGS=()
if [[ "$CREATE_REGISTRY" == "true" ]]; then
  bash "$SCRIPT_DIR/create-registry.sh"
  REG_ARGS+=(--registry-use "k3d-${REGISTRY_NAME}:${REGISTRY_HOST_PORT}")
fi

if k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -Fxq "$CLUSTER_NAME"; then
  echo "Cluster $CLUSTER_NAME already exists"
  if [[ "$CREATE_REGISTRY" == "true" ]]; then
    bash "$SCRIPT_DIR/create-registry.sh"
  fi
else
  k3d cluster create "$CLUSTER_NAME" \
    --servers 1 \
    --agents 2 \
    --api-port "$API_PORT" \
    --port "${HTTP_PORT}:80@loadbalancer" \
    --port "${HTTPS_PORT}:443@loadbalancer" \
    --k3s-arg '--disable=traefik@server:*' \
    "${REG_ARGS[@]}" \
    --wait
fi

kubectl config use-context "k3d-${CLUSTER_NAME}"
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl get nodes -o wide
