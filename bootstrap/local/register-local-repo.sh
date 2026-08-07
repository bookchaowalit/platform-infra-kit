#!/usr/bin/env bash
# Prepare a local git snapshot of the monorepo for Argo CD file:// access
# on disposable k3d-solo-dev only.
set -euo pipefail

export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-solo-dev}"
CONTEXT="k3d-${CLUSTER_NAME}"
SNAP_DIR="${SNAP_DIR:-/tmp/solo-empire-argocd-snapshot}"

kubectl config use-context "$CONTEXT" >/dev/null

echo "Building Argo CD snapshot at $SNAP_DIR"
rm -rf "$SNAP_DIR"
mkdir -p "$SNAP_DIR"

# Minimal tree required for the pilot Application sources
mkdir -p "$SNAP_DIR/infra/platform"
cp -a "$REPO_ROOT/infra/platform/helm" "$SNAP_DIR/infra/platform/"
cp -a "$REPO_ROOT/infra/platform/gitops" "$SNAP_DIR/infra/platform/"
mkdir -p "$SNAP_DIR/engagements/internal/solo-empire"
if [[ -d "$REPO_ROOT/engagements/internal/solo-empire/ai-doc-assistant" ]]; then
  cp -a "$REPO_ROOT/engagements/internal/solo-empire/ai-doc-assistant" \
    "$SNAP_DIR/engagements/internal/solo-empire/"
fi

# Init git on host (nodes may not have git)
git -C "$SNAP_DIR" init -q
git -C "$SNAP_DIR" config user.email "lab@local"
git -C "$SNAP_DIR" config user.name "solo-empire-lab"
git -C "$SNAP_DIR" add -A
git -C "$SNAP_DIR" commit -q -m "local-pilot-snapshot"

# Copy snapshot onto every k3d node at /solo-empire
NODE_CONTAINERS=$(docker ps --filter "name=k3d-${CLUSTER_NAME}-server" --filter "name=k3d-${CLUSTER_NAME}-agent" --format '{{.Names}}')
# Also match broader in case naming differs
if [[ -z "$NODE_CONTAINERS" ]]; then
  NODE_CONTAINERS=$(docker ps --filter "name=k3d-${CLUSTER_NAME}" --format '{{.Names}}' | grep -v tools | grep -v serverlb || true)
fi

for node in $NODE_CONTAINERS; do
  case "$node" in
    *tools*|*serverlb*) continue ;;
  esac
  echo "Syncing snapshot to $node:/solo-empire"
  docker exec "$node" rm -rf /solo-empire
  docker exec "$node" mkdir -p /solo-empire
  docker cp "$SNAP_DIR/." "$node:/solo-empire/"
done

# JSON patch: add hostPath volume without replacing the container image
if ! kubectl -n argocd get deploy argocd-repo-server -o json | grep -q 'solo-empire-repo'; then
  kubectl -n argocd patch deployment argocd-repo-server --type='json' -p='[
    {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"solo-empire-repo","hostPath":{"path":"/solo-empire","type":"Directory"}}},
    {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"solo-empire-repo","mountPath":"/workspace/solo-empire","readOnly":true}}
  ]'
else
  echo "argocd-repo-server already mounts solo-empire-repo"
fi

kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=180s

# Verify mount inside repo-server
POD=$(kubectl -n argocd get pod -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')
kubectl -n argocd exec "$POD" -- ls /workspace/solo-empire/infra/platform/helm/solo-app/Chart.yaml
echo "Registered local monorepo at file:///workspace/solo-empire"
