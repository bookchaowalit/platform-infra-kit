#!/usr/bin/env bash
# Build ai-doc-assistant with immutable git-SHA tag and push to homelab registry.
# Never uses :latest. Does not print registry passwords.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
APP_DIR="${ROOT}/engagements/internal/solo-empire/ai-doc-assistant"
REGISTRY_HOST="${REGISTRY_HOST:-registry.homelab.local}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
IMAGE_NAME="${IMAGE_NAME:-solo-empire/ai-doc-assistant}"
if [[ -z "${GIT_SHA:-}" ]]; then
  # The application is a separate nested repository. Use its commit so the
  # immutable image tag identifies the source that was actually built.
  GIT_SHA="$(git -C "${APP_DIR}" rev-parse HEAD 2>/dev/null || git -C "${ROOT}" rev-parse HEAD)"
fi
TAG="git-${GIT_SHA}"
FULL_IMAGE="${REGISTRY_HOST}:${REGISTRY_PORT}/${IMAGE_NAME}:${TAG}"

if [[ ! -f "${APP_DIR}/Dockerfile" ]]; then
  echo "ERROR: Dockerfile missing at ${APP_DIR}" >&2
  exit 1
fi
command -v docker >/dev/null

echo "Building ${FULL_IMAGE}"
docker build -t "${FULL_IMAGE}" "${APP_DIR}"
echo "Pushing ${FULL_IMAGE}"
docker push "${FULL_IMAGE}"

# Also tag previous short alias is forbidden (:latest). Optionally keep second
# immutable tag for rollback drills when ROLLBACK_SHA is set.
if [[ -n "${ROLLBACK_SHA:-}" ]]; then
  ROLLBACK_TAG="git-${ROLLBACK_SHA}"
  ROLLBACK_IMAGE="${REGISTRY_HOST}:${REGISTRY_PORT}/${IMAGE_NAME}:${ROLLBACK_TAG}"
  docker tag "${FULL_IMAGE}" "${ROLLBACK_IMAGE}"
  docker push "${ROLLBACK_IMAGE}"
  echo "Also pushed rollback tag ${ROLLBACK_IMAGE}"
fi

echo "IMAGE_REPOSITORY=${REGISTRY_HOST}:${REGISTRY_PORT}/${IMAGE_NAME}"
echo "IMAGE_TAG=${TAG}"
echo "FULL_IMAGE=${FULL_IMAGE}"
