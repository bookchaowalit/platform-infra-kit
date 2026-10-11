#!/usr/bin/env bash
# Unified local pilot deploy for any onboarded app (k3d-solo-dev only).
# Usage: deploy-app.sh <app-name>
# Reads infra/platform/onboarding/apps/<app-name>.yaml
#
# - Git-SHA image tags (not :latest, not git-pending)
# - Local k3d registry push/pull
# - Argo CD Application from onboarding / bootstrap templates
set -euo pipefail

export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"
BOOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$BOOT/../../../.." && pwd)"
ONBOARDING="$ROOT/infra/platform/onboarding"
SCRIPTS="$ONBOARDING/scripts"

APP_NAME="${1:-}"
if [[ -z "$APP_NAME" ]]; then
  echo "Usage: $0 <app-name>" >&2
  echo "Known apps:" >&2
  ls -1 "$ONBOARDING/apps"/*.yaml 2>/dev/null | xargs -n1 basename | sed 's/\.yaml$//' | sed 's/^/  /' || true
  exit 1
fi

if [[ ! -f "$ONBOARDING/apps/${APP_NAME}.yaml" ]]; then
  echo "ERROR: missing app definition $ONBOARDING/apps/${APP_NAME}.yaml" >&2
  echo "Scaffold with: python3 infra/platform/onboarding/scripts/onboard-app.py --name $APP_NAME ..." >&2
  exit 1
fi

# shellcheck disable=SC1090
eval "$(python3 "$SCRIPTS/app_env.py" "$APP_NAME")"

if [[ ! -f "$BOOT/pilot.env" ]]; then
  cp "$BOOT/pilot.env.example" "$BOOT/pilot.env"
  echo "Created $BOOT/pilot.env from example (edit as needed)."
fi
# shellcheck disable=SC1091
source "$BOOT/pilot.env"

CLUSTER_NAME="${CLUSTER_NAME:-solo-dev}"
CONTEXT="k3d-${CLUSTER_NAME}"
APP_DIR="$ROOT/${APP_SOURCE_PATH}"
IMAGE_NAME="${IMAGE_NAME:-$APP_IMAGE_NAME}"
REGISTRY_HOST_PORT="${REGISTRY_HOST_PORT:-5111}"
REGISTRY_NAME="${REGISTRY_NAME:-solo-registry}"
ARGO_APP_NAME="${APP_ARGO}"
NS="${APP_NS}"

if [[ ! -d "$APP_DIR" ]]; then
  echo "ERROR: app source not found: $APP_DIR" >&2
  exit 1
fi
if [[ ! -f "$APP_DIR/Dockerfile" ]]; then
  echo "ERROR: Dockerfile missing under $APP_DIR" >&2
  exit 1
fi

VALUES_SRC="$ROOT/infra/platform/gitops/applications/values/dev/${APP_NAME}.yaml"
if [[ ! -f "$VALUES_SRC" ]]; then
  echo "ERROR: missing values file $VALUES_SRC" >&2
  echo "Run onboard-app.py --from-definition for $APP_NAME" >&2
  exit 1
fi

ARGO_TPL="$BOOT/applications/${APP_NAME}-dev.yaml.tpl"
# Prefer per-app template; fall back to onboarding generic template rendered with name
if [[ ! -f "$ARGO_TPL" ]]; then
  GENERIC="$ONBOARDING/templates/argo-application.yaml.tpl"
  if [[ ! -f "$GENERIC" ]]; then
    echo "ERROR: missing Argo template $ARGO_TPL" >&2
    exit 1
  fi
  mkdir -p "$BOOT/applications"
  sed \
    -e "s|__APP_NAME__|${APP_NAME}|g" \
    -e "s|__TEAM__|${APP_TEAM}|g" \
    "$GENERIC" >"$ARGO_TPL"
  echo "Generated $ARGO_TPL from onboarding template"
fi

GIT_SHA="$(git -C "$ROOT" rev-parse HEAD)"
GIT_SHA_SHORT="$(git -C "$ROOT" rev-parse --short HEAD)"
if [[ -z "${IMAGE_TAG:-}" ]]; then
  IMAGE_TAG="git-${GIT_SHA}"
fi
if [[ "$IMAGE_TAG" == "latest" || "$IMAGE_TAG" == "0.1.0-local" || "$IMAGE_TAG" == "git-pending" ]]; then
  echo "Refusing mutable/placeholder tag: $IMAGE_TAG" >&2
  echo "Unset IMAGE_TAG to use git-${GIT_SHA}" >&2
  exit 1
fi
if [[ "$IMAGE_TAG" != git-* ]]; then
  echo "WARNING: IMAGE_TAG=$IMAGE_TAG does not look like git-<sha> (continuing)" >&2
fi

kubectl config use-context "$CONTEXT"

echo "==> Local registry"
RELOAD_REGISTRY="${RELOAD_REGISTRY:-false}" bash "$BOOT/create-registry.sh"
if [[ -f "$BOOT/pilot.env" ]]; then
  REGISTRY_PUSH_HOST="$(grep -E '^REGISTRY_PUSH_HOST=' "$BOOT/pilot.env" | tail -1 | cut -d= -f2- || true)"
  REGISTRY_PULL_HOST="$(grep -E '^REGISTRY_PULL_HOST=' "$BOOT/pilot.env" | tail -1 | cut -d= -f2- || true)"
fi
REGISTRY_PUSH_HOST="${REGISTRY_PUSH_HOST:-localhost:${REGISTRY_HOST_PORT}}"
REGISTRY_PULL_HOST="${REGISTRY_PULL_HOST:-k3d-${REGISTRY_NAME}:5000}"
if [[ -z "${IMAGE_TAG:-}" ]]; then
  IMAGE_TAG="git-${GIT_SHA}"
fi

IMAGE_PUSH="${REGISTRY_PUSH_HOST}/${IMAGE_NAME}:${IMAGE_TAG}"
IMAGE_PULL_REPO="${REGISTRY_PULL_HOST}/${IMAGE_NAME}"

echo "==> Build ${IMAGE_PUSH} (git ${GIT_SHA_SHORT}) app=${APP_NAME}"
docker build -t "${IMAGE_PUSH}" "$APP_DIR"
docker tag "${IMAGE_PUSH}" "${IMAGE_NAME}:${IMAGE_TAG}"

echo "==> Push to local registry"
docker push "${IMAGE_PUSH}"

echo "==> Ensure ingress-nginx"
if ! kubectl get ns ingress-nginx >/dev/null 2>&1; then
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    --set controller.service.type=LoadBalancer \
    --set controller.admissionWebhooks.enabled=false \
    --wait --timeout 5m
fi

echo "==> Package pilot values into chart path"
mkdir -p "$ROOT/infra/platform/helm/solo-app/pilot"
cp "$ROOT/infra/platform/gitops/applications/values/dev/common.yaml" \
  "$ROOT/infra/platform/helm/solo-app/pilot/dev-common.yaml"
# Keep GitOps values canonical. Pilot values are disposable local renderings
# consumed by the temporary Git source created below.
python3 - <<PY
from pathlib import Path
import re
repo = "${IMAGE_PULL_REPO}"
tag = "${IMAGE_TAG}"
src = Path("${VALUES_SRC}")
t = src.read_text()
t = re.sub(r"^(  repository:).*$", f"  repository: {repo}", t, flags=re.M)
t = re.sub(r"^(  tag:).*$", f'  tag: "{tag}"', t, flags=re.M)
t = re.sub(r"^(  pullPolicy:).*$", "  pullPolicy: Always", t, flags=re.M)
Path("$ROOT/infra/platform/helm/solo-app/pilot/${APP_NAME}-dev.yaml").write_text(t)
print("packaged", repo, tag)
PY

echo "==> Git source for Argo CD (refresh snapshot)"
USE_LOCAL_GIT=true
if [[ -n "${ARGOCD_REPO_URL:-}" && "$ARGOCD_REPO_URL" != file://* && "$ARGOCD_REPO_URL" != git://* && "$ARGOCD_REPO_URL" != *host.k3d.internal* ]]; then
  USE_LOCAL_GIT=false
  echo "Using configured remote Git: $ARGOCD_REPO_URL"
fi
if [[ "$USE_LOCAL_GIT" == "true" ]]; then
  bash "$BOOT/start-local-git-source.sh"
  ARGOCD_REPO_URL="$(grep -E '^ARGOCD_REPO_URL=' "$BOOT/pilot.env" | tail -1 | cut -d= -f2-)"
  ARGOCD_TARGET_REVISION="$(grep -E '^ARGOCD_TARGET_REVISION=' "$BOOT/pilot.env" | tail -1 | cut -d= -f2-)"
fi
ARGOCD_TARGET_REVISION="${ARGOCD_TARGET_REVISION:-main}"
if [[ -z "${IMAGE_TAG:-}" ]]; then
  IMAGE_TAG="git-${GIT_SHA}"
fi

export IMAGE_REPOSITORY="${IMAGE_PULL_REPO}"
export IMAGE_TAG
export ARGOCD_REPO_URL
export ARGOCD_TARGET_REVISION

OUT="$BOOT/applications/${APP_NAME}-dev.yaml"
sed \
  -e "s|__APP_NAME__|${APP_NAME}|g" \
  -e "s|__TEAM__|${APP_TEAM}|g" \
  -e "s|__ARGOCD_REPO_URL__|${ARGOCD_REPO_URL//|/\\|}|g" \
  -e "s|__ARGOCD_TARGET_REVISION__|${ARGOCD_TARGET_REVISION//|/\\|}|g" \
  -e "s|__IMAGE_REPOSITORY__|${IMAGE_REPOSITORY//|/\\|}|g" \
  -e "s|__IMAGE_TAG__|${IMAGE_TAG//|/\\|}|g" \
  "$ARGO_TPL" >"$OUT"
echo "Rendered $OUT"

# Ensure AppProject allows apps-* destinations
kubectl apply -f "$BOOT/argocd-apps-project.yaml"
kubectl apply -f "$OUT"

if [[ "$ARGOCD_REPO_URL" == git://* || "$ARGOCD_REPO_URL" == http://* ]]; then
  kubectl -n argocd apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-solo-empire-local-pilot
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${ARGOCD_REPO_URL}
  insecure: "true"
  enableLfs: "false"
EOF
fi

echo "==> Wait for Application Synced/Healthy (${ARGO_APP_NAME})"
for i in $(seq 1 72); do
  STATUS=$(kubectl -n argocd get application "$ARGO_APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo 'Unknown')
  HEALTH=$(kubectl -n argocd get application "$ARGO_APP_NAME" -o jsonpath='{.status.health.status}' 2>/dev/null || echo 'Unknown')
  echo "  attempt $i: sync=$STATUS health=$HEALTH"
  if [[ "$STATUS" == "Synced" && "$HEALTH" == "Healthy" ]]; then
    break
  fi
  if (( i % 5 == 0 )); then
    kubectl -n argocd annotate application "$ARGO_APP_NAME" \
      argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  fi
  sleep 10
done

kubectl -n argocd get application "$ARGO_APP_NAME"
kubectl -n "$NS" get pods,svc,ingress,networkpolicy 2>/dev/null || true
echo "Image: ${IMAGE_PULL_REPO}:${IMAGE_TAG}"
echo "Git:   ${ARGOCD_REPO_URL} @ ${ARGOCD_TARGET_REVISION}"
echo "Deploy finished for ${APP_NAME}."
