#!/usr/bin/env bash
# Prepare a local git snapshot of the repository for Argo CD file:// access
# on disposable k3d-solo-dev only.
set -euo pipefail

export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-solo-dev}"
CONTEXT="k3d-${CLUSTER_NAME}"
SNAP_DIR="${SNAP_DIR:-/tmp/solo-platform-kit-argocd-snapshot}"

kubectl config use-context "$CONTEXT" >/dev/null

echo "Building Argo CD snapshot at $SNAP_DIR"
rm -rf "$SNAP_DIR"
mkdir -p "$SNAP_DIR"

# Minimal tree required for the pilot Application sources
mkdir -p "$SNAP_DIR/infra/platform"
cp -a "$REPO_ROOT/infra/platform/helm" "$SNAP_DIR/infra/platform/"
cp -a "$REPO_ROOT/infra/platform/gitops" "$SNAP_DIR/infra/platform/"
mkdir -p "$SNAP_DIR/projects/product/engineering/book-dev/github/bookchaowalit/private"
APP_SRC="${SOLO_BOOK_DEV_ROOT:+$SOLO_BOOK_DEV_ROOT/github/bookchaowalit/private/ai-doc-assistant}"
if [[ -n "$APP_SRC" && -d "$APP_SRC" ]]; then
  cp -a "$APP_SRC" \
    "$SNAP_DIR/projects/product/engineering/book-dev/github/bookchaowalit/private/"
fi

# Init git on host (nodes may not have git)
git -C "$SNAP_DIR" init -q
git -C "$SNAP_DIR" config user.email "lab@local"
git -C "$SNAP_DIR" config user.name "solo-platform-kit-lab"
git -C "$SNAP_DIR" add -A
git -C "$SNAP_DIR" commit -q -m "local-pilot-snapshot"

# Copy snapshot onto every k3d node at /solo-platform-kit
NODE_CONTAINERS=$(docker ps --filter "name=k3d-${CLUSTER_NAME}-server" --filter "name=k3d-${CLUSTER_NAME}-agent" --format '{{.Names}}')
# Also match broader in case naming differs
if [[ -z "$NODE_CONTAINERS" ]]; then
  NODE_CONTAINERS=$(docker ps --filter "name=k3d-${CLUSTER_NAME}" --format '{{.Names}}' | grep -v tools | grep -v serverlb || true)
fi

for node in $NODE_CONTAINERS; do
  case "$node" in
    *tools*|*serverlb*) continue ;;
  esac
  echo "Syncing snapshot to $node:/solo-platform-kit"
  docker exec "$node" rm -rf /solo-platform-kit
  docker exec "$node" mkdir -p /solo-platform-kit
  docker cp "$SNAP_DIR/." "$node:/solo-platform-kit/"
done

# JSON patch: add hostPath volume without replacing the container image
if ! kubectl -n argocd get deploy argocd-repo-server -o json | grep -q 'solo-platform-kit-repo'; then
  kubectl -n argocd patch deployment argocd-repo-server --type='json' -p='[
    {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"solo-platform-kit-repo","hostPath":{"path":"/solo-platform-kit","type":"Directory"}}},
    {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"solo-platform-kit-repo","mountPath":"/workspace/solo-platform-kit","readOnly":true}}
  ]'
else
  echo "argocd-repo-server already mounts solo-platform-kit-repo"
fi

kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=180s

# Verify mount inside repo-server
POD=$(kubectl -n argocd get pod -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')
kubectl -n argocd exec "$POD" -- ls /workspace/solo-platform-kit/infra/platform/helm/solo-app/Chart.yaml
echo "Registered local repository at file:///workspace/solo-platform-kit"
