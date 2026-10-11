#!/usr/bin/env bash
# Create the optional OpenAI Secret outside Git (never prints the value).
# Usage:
#   export OPENAI_API_KEY='...'   # from your secret store, not from chat
#   ./create-pilot-secret.sh
set -euo pipefail

export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"
NS="${NS:-apps-ai-doc-assistant-dev}"
SECRET_NAME="${SECRET_NAME:-ai-doc-assistant-openai}"

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "OPENAI_API_KEY is not set in the environment."
  echo "Export it from your secret manager, then re-run. Nothing was written."
  exit 1
fi

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"

# --dry-run=client -o yaml | apply avoids shell history echoes of the key in some setups
kubectl -n "$NS" create secret generic "$SECRET_NAME" \
  --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# Clear from this process environment (caller shell may still hold it)
unset OPENAI_API_KEY

echo "Secret ${SECRET_NAME} applied in namespace ${NS} (value not printed)."
echo "Enable mounting via pilot values externalSecrets or envFromSecrets (see runbook)."
