#!/usr/bin/env bash
set -euo pipefail

BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
export PATH="$BIN_DIR:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE=platform
SOURCE_SECRET=eso-local-source
DERIVED_SECRET=eso-local-derived

cleanup() {
  kubectl delete -f "$ROOT/external-secrets-smoke.yaml" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" delete secret "$SOURCE_SECRET" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl -n "$NAMESPACE" create secret generic "$SOURCE_SECRET" \
  --from-literal=demo=local-only-smoke-value \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f "$ROOT/external-secrets-smoke.yaml" >/dev/null

if ! kubectl -n "$NAMESPACE" wait --for=condition=Ready \
  "externalsecret/$DERIVED_SECRET" --timeout=120s; then
  kubectl -n "$NAMESPACE" describe externalsecret "$DERIVED_SECRET" >&2 || true
  echo 'External Secrets smoke test failed' >&2
  exit 1
fi

value="$(kubectl -n "$NAMESPACE" get secret "$DERIVED_SECRET" \
  -o jsonpath='{.data.demo}' | base64 -d)"
if [[ "$value" != local-only-smoke-value ]]; then
  echo 'External Secrets smoke test produced an unexpected value' >&2
  exit 1
fi

echo 'External Secrets smoke test: OK (dummy value projected; cleanup scheduled)'
