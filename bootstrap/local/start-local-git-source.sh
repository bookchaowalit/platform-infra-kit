#!/usr/bin/env bash
# Build a disposable local Git source and serve it with git-daemon **on the k3d
# Docker network** so Argo CD repo-server can clone without host routing hacks.
# No production credentials. Lab only.
set -euo pipefail

export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
BOOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -f "$BOOT/pilot.env" ]] && source "$BOOT/pilot.env"

CLUSTER_NAME="${CLUSTER_NAME:-solo-dev}"
GIT_CONTAINER="${GIT_CONTAINER:-k3d-solo-git}"
GIT_PORT="${GIT_DAEMON_PORT:-9418}"
SNAP_SRC="${SNAP_SRC:-/tmp/solo-empire-pilot-src}"
BARE_PARENT="${BARE_PARENT:-/tmp/git-export}"
BARE_REPO="${BARE_PARENT}/solo-empire-pilot.git"
NET="k3d-${CLUSTER_NAME}"

echo "Building local git snapshot..."
rm -rf "$SNAP_SRC" "$BARE_REPO"
mkdir -p "$SNAP_SRC" "$BARE_PARENT"

rsync -a \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude '.venv' \
  --exclude 'infra/node_modules' \
  --exclude 'infra/mcp-server/node_modules' \
  --exclude '**/__pycache__' \
  "$ROOT/" "$SNAP_SRC/"

if [[ -d "$ROOT/jobs/internal/solo-empire/ai-doc-assistant" ]]; then
  rm -rf "$SNAP_SRC/jobs/internal/solo-empire/ai-doc-assistant"
  mkdir -p "$SNAP_SRC/jobs/internal/solo-empire"
  rsync -a --exclude '.git' --exclude '.venv' --exclude '__pycache__' \
    "$ROOT/jobs/internal/solo-empire/ai-doc-assistant/" \
    "$SNAP_SRC/jobs/internal/solo-empire/ai-doc-assistant/"
fi

git -C "$SNAP_SRC" init -q
git -C "$SNAP_SRC" config user.email "lab@local"
git -C "$SNAP_SRC" config user.name "solo-empire-lab"
git -C "$SNAP_SRC" add -A
git -C "$SNAP_SRC" commit -q -m "local-pilot-snapshot $(date -u +%Y%m%dT%H%M%SZ)" || true
git -C "$SNAP_SRC" branch -M main 2>/dev/null || true

git clone --bare -q "$SNAP_SRC" "$BARE_REPO"
touch "$BARE_REPO/git-daemon-export-ok"
git -C "$BARE_REPO" update-server-info

# Recreate git-daemon container on the k3d network
docker rm -f "$GIT_CONTAINER" >/dev/null 2>&1 || true
if ! docker network inspect "$NET" >/dev/null 2>&1; then
  echo "ERROR: docker network $NET not found; is cluster ${CLUSTER_NAME} running?" >&2
  exit 1
fi

# Alpine + git-daemon on the k3d network (reachable by Argo CD repo-server)
docker run -d --name "$GIT_CONTAINER" \
  --network "$NET" \
  --restart unless-stopped \
  -v "${BARE_PARENT}:/git:ro" \
  alpine:3.20 \
  sh -c "apk add --no-cache git git-daemon >/dev/null && git config --global --add safe.directory '*' && exec git daemon --reuseaddr --verbose --export-all --base-path=/git --listen=0.0.0.0 --port=${GIT_PORT} /git" \
  >/dev/null

# Allow packages to install + daemon start
sleep 5

# In-cluster DNS name is the container name on the k3d network
ARGOCD_REPO_URL="git://${GIT_CONTAINER}:${GIT_PORT}/solo-empire-pilot.git"
ARGOCD_TARGET_REVISION="main"

if [[ -f "$BOOT/pilot.env" ]]; then
  grep -q '^ARGOCD_REPO_URL=' "$BOOT/pilot.env" \
    && sed -i "s|^ARGOCD_REPO_URL=.*|ARGOCD_REPO_URL=${ARGOCD_REPO_URL}|" "$BOOT/pilot.env" \
    || echo "ARGOCD_REPO_URL=${ARGOCD_REPO_URL}" >>"$BOOT/pilot.env"
  grep -q '^ARGOCD_TARGET_REVISION=' "$BOOT/pilot.env" \
    && sed -i "s|^ARGOCD_TARGET_REVISION=.*|ARGOCD_TARGET_REVISION=${ARGOCD_TARGET_REVISION}|" "$BOOT/pilot.env" \
    || echo "ARGOCD_TARGET_REVISION=${ARGOCD_TARGET_REVISION}" >>"$BOOT/pilot.env"
fi

# Smoke from a throwaway container on the same network
docker run --rm --network "$NET" --entrypoint sh alpine/git:latest \
  -c "git ls-remote ${ARGOCD_REPO_URL} HEAD" >/dev/null

echo "Local git-daemon source ready on k3d network (no credentials)."
echo "  ARGOCD_REPO_URL=${ARGOCD_REPO_URL}"
echo "  ARGOCD_TARGET_REVISION=${ARGOCD_TARGET_REVISION}"
echo "  Stop with: docker rm -f ${GIT_CONTAINER}"
