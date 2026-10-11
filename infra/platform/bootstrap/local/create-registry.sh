#!/usr/bin/env bash
# Create a disposable k3d-managed local registry and attach it to solo-dev.
# No production credentials. Local/dev only.
set -euo pipefail

export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/pilot.env" ]] && source "$ROOT/pilot.env"

CLUSTER_NAME="${CLUSTER_NAME:-solo-dev}"
REGISTRY_NAME="${REGISTRY_NAME:-solo-registry}"
REGISTRY_HOST_PORT="${REGISTRY_HOST_PORT:-5111}"
K3D_REG="k3d-${REGISTRY_NAME}"

command -v k3d >/dev/null
command -v docker >/dev/null

if k3d registry list -o json 2>/dev/null | grep -q "\"${K3D_REG}\"" \
  || docker ps --format '{{.Names}}' | grep -qx "${K3D_REG}"; then
  echo "Registry ${K3D_REG} already exists"
else
  echo "Creating registry ${K3D_REG} on localhost:${REGISTRY_HOST_PORT}"
  k3d registry create "${REGISTRY_NAME}" --port "0.0.0.0:${REGISTRY_HOST_PORT}"
fi

# Connect registry to cluster network if not already
if k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -Fxq "$CLUSTER_NAME"; then
  echo "Connecting registry to cluster ${CLUSTER_NAME}"
  # k3d v5+: network connect is automatic when using --registry-use at create;
  # for existing clusters, attach the registry container to the cluster network.
  NET="k3d-${CLUSTER_NAME}"
  if docker network inspect "$NET" >/dev/null 2>&1; then
    docker network connect "$NET" "${K3D_REG}" 2>/dev/null || true
  fi

  # Configure containerd on nodes to trust the local registry (HTTP)
  for node in $(docker ps --format '{{.Names}}' | grep "^k3d-${CLUSTER_NAME}-" | grep -v tools | grep -v serverlb || true); do
    echo "Configuring registries on ${node}"
    docker exec "$node" mkdir -p /etc/rancher/k3s
    # Merge-style registries.yaml for HTTP local registry
    docker exec -i "$node" sh -c "cat > /etc/rancher/k3s/registries.yaml" <<EOF
mirrors:
  "${K3D_REG}:5000":
    endpoint:
      - "http://${K3D_REG}:5000"
  "localhost:${REGISTRY_HOST_PORT}":
    endpoint:
      - "http://${K3D_REG}:5000"
configs:
  "${K3D_REG}:5000":
    tls:
      insecure_skip_verify: true
EOF
  done
  # Restart nodes so containerd reloads registries.yaml (HTTP local registry)
  if [[ "${RELOAD_REGISTRY:-true}" == "true" ]]; then
    for node in $(docker ps --format '{{.Names}}' | grep "^k3d-${CLUSTER_NAME}-" | grep -vE 'tools|serverlb' || true); do
      echo "Restarting ${node} to reload registries.yaml"
      docker restart "$node" >/dev/null
    done
    sleep 12
    kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null
    kubectl wait --for=condition=Ready nodes --all --timeout=180s
  fi
fi

# Export helpers for pilot.env consumers
# Host publishes REGISTRY_HOST_PORT → container 5000; in-cluster use :5000
PUSH_HOST="localhost:${REGISTRY_HOST_PORT}"
PULL_HOST="${K3D_REG}:5000"

if [[ -f "$ROOT/pilot.env" ]]; then
  # Update or append registry endpoints without printing secrets
  grep -q '^REGISTRY_PUSH_HOST=' "$ROOT/pilot.env" \
    && sed -i "s|^REGISTRY_PUSH_HOST=.*|REGISTRY_PUSH_HOST=${PUSH_HOST}|" "$ROOT/pilot.env" \
    || echo "REGISTRY_PUSH_HOST=${PUSH_HOST}" >>"$ROOT/pilot.env"
  grep -q '^REGISTRY_PULL_HOST=' "$ROOT/pilot.env" \
    && sed -i "s|^REGISTRY_PULL_HOST=.*|REGISTRY_PULL_HOST=${PULL_HOST}|" "$ROOT/pilot.env" \
    || echo "REGISTRY_PULL_HOST=${PULL_HOST}" >>"$ROOT/pilot.env"
fi

echo "Registry ready."
echo "  Push from host:  ${PUSH_HOST}/<image>:<tag>"
echo "  Pull in cluster: ${PULL_HOST}/<image>:<tag>"
echo "  Example: docker tag myimg:tag ${PUSH_HOST}/solo-empire/ai-doc-assistant:git-abc123"
echo "           docker push ${PUSH_HOST}/solo-empire/ai-doc-assistant:git-abc123"
