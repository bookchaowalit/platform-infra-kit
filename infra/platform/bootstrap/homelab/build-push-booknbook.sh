#!/usr/bin/env bash
# Build booknbook with an immutable nested-repository commit tag and push it
# to the private Fedora registry. Never uses :latest; never prints secrets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
APP_DIR="${ROOT}/projects/product/engineering/book-dev/github/bookchaowalit-website/public/book-products/booknbook"
REGISTRY_HOST="${REGISTRY_HOST:-registry.homelab.local}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
IMAGE_NAME="${IMAGE_NAME:-solo-empire/booknbook}"

if [[ -z "${GIT_SHA:-}" ]]; then
  GIT_SHA="$(git -C "${APP_DIR}" rev-parse HEAD)"
fi
TAG="git-${GIT_SHA}"
FULL_IMAGE="${REGISTRY_HOST}:${REGISTRY_PORT}/${IMAGE_NAME}:${TAG}"

[[ -f "${APP_DIR}/Dockerfile" ]] || { echo "ERROR: Dockerfile missing at ${APP_DIR}" >&2; exit 1; }
command -v docker >/dev/null

echo "Building ${FULL_IMAGE}"
docker build -t "${FULL_IMAGE}" "${APP_DIR}"
echo "Pushing ${FULL_IMAGE}"
docker push "${FULL_IMAGE}"

echo "IMAGE_REPOSITORY=${REGISTRY_HOST}:${REGISTRY_PORT}/${IMAGE_NAME}"
echo "IMAGE_TAG=${TAG}"
echo "FULL_IMAGE=${FULL_IMAGE}"
