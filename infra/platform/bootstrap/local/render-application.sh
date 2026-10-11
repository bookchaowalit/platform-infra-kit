#!/usr/bin/env bash
# Render a pilot Argo CD Application from template + pilot.env
# Usage:
#   render-application.sh [output-path]
#   APP=booknbook render-application.sh
# Defaults to ai-doc-assistant for backward compatibility.
set -euo pipefail

BOOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$BOOT/../../../.." && pwd)"
APP_NAME="${APP:-${APP_NAME:-ai-doc-assistant}}"

# Load pilot.env only for variables not already set in the environment
if [[ -f "$BOOT/pilot.env" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    [[ -z "$val" ]] && continue
    if [[ -z "${!key+x}" || -z "${!key}" ]]; then
      export "$key=$val"
    fi
  done <"$BOOT/pilot.env"
fi

: "${ARGOCD_REPO_URL:?Set ARGOCD_REPO_URL in pilot.env (run start-local-git-source.sh or set a Git HTTPS URL)}"
: "${ARGOCD_TARGET_REVISION:=HEAD}"
: "${IMAGE_REPOSITORY:?Set IMAGE_REPOSITORY (registry pull host + image name)}"
: "${IMAGE_TAG:?Set IMAGE_TAG (git SHA tag, not latest)}"

if [[ "$IMAGE_TAG" == "latest" || "$IMAGE_TAG" == "git-pending" || "$IMAGE_TAG" == "0.1.0-local" ]]; then
  echo "ERROR: IMAGE_TAG must be immutable (not latest/git-pending/0.1.0-local)" >&2
  exit 1
fi
if [[ "$ARGOCD_REPO_URL" == file://* ]]; then
  echo "ERROR: file:// Argo CD sources are no longer supported; use a Git URL" >&2
  exit 1
fi

# Optional team from app definition
APP_TEAM="${APP_TEAM:-product}"
if [[ -f "$ROOT/infra/platform/onboarding/apps/${APP_NAME}.yaml" ]]; then
  # shellcheck disable=SC1090
  eval "$(python3 "$ROOT/infra/platform/onboarding/scripts/app_env.py" "$APP_NAME" 2>/dev/null || true)"
fi

TPL="$BOOT/applications/${APP_NAME}-dev.yaml.tpl"
if [[ ! -f "$TPL" ]]; then
  GENERIC="$ROOT/infra/platform/onboarding/templates/argo-application.yaml.tpl"
  if [[ ! -f "$GENERIC" ]]; then
    echo "ERROR: missing template for $APP_NAME" >&2
    exit 1
  fi
  mkdir -p "$BOOT/applications"
  sed -e "s|__APP_NAME__|${APP_NAME}|g" -e "s|__TEAM__|${APP_TEAM}|g" "$GENERIC" >"$TPL"
fi

OUT="${1:-$BOOT/applications/${APP_NAME}-dev.yaml}"
sed \
  -e "s|__APP_NAME__|${APP_NAME}|g" \
  -e "s|__TEAM__|${APP_TEAM}|g" \
  -e "s|__ARGOCD_REPO_URL__|${ARGOCD_REPO_URL//|/\\|}|g" \
  -e "s|__ARGOCD_TARGET_REVISION__|${ARGOCD_TARGET_REVISION//|/\\|}|g" \
  -e "s|__IMAGE_REPOSITORY__|${IMAGE_REPOSITORY//|/\\|}|g" \
  -e "s|__IMAGE_TAG__|${IMAGE_TAG//|/\\|}|g" \
  "$TPL" >"$OUT"

echo "Rendered $OUT"
echo "  app=$APP_NAME"
echo "  repoURL=$ARGOCD_REPO_URL"
echo "  targetRevision=$ARGOCD_TARGET_REVISION"
echo "  image=${IMAGE_REPOSITORY}:${IMAGE_TAG}"
