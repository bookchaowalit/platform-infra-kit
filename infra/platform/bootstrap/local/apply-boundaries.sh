#!/usr/bin/env bash
set -euo pipefail

BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
export PATH="$BIN_DIR:$PATH"

kubectl cluster-info >/dev/null
kubectl apply -f "$(dirname "$0")/namespaces.yaml"
kubectl apply -f "$(dirname "$0")/../../policies/kyverno/"
kubectl apply -f "$(dirname "$0")/argocd-platform-project.yaml"

policy_names="$(kubectl get clusterpolicy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -v '^image-provenance-placeholder$' || true)"
while IFS= read -r policy_name; do
  [[ -z "$policy_name" ]] && continue
  kubectl wait --for=condition=Ready "clusterpolicy/$policy_name" --timeout=120s
done <<< "$policy_names"
echo 'Local platform boundaries applied; no application source was enabled.'
kubectl get clusterpolicy
kubectl -n argocd get appproject solo-empire-platform
