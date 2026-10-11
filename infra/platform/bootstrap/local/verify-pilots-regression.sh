#!/usr/bin/env bash
# Regression checks for all onboarded local pilots (k3d-solo-dev only).
# Verifies Argo Synced/Healthy, Pod Ready, healthz/readyz HTTP 200, NetworkPolicy.
set -uo pipefail

export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"
BOOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$BOOT/../../../.." && pwd)"
ONBOARDING="$ROOT/infra/platform/onboarding"
CLUSTER_NAME="${CLUSTER_NAME:-solo-dev}"
CONTEXT="k3d-${CLUSTER_NAME}"
INGRESS_PORT="${INGRESS_PORT:-18080}"

PASS=0
FAIL=0
REPORT=()

log()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); REPORT+=("PASS  $*"); log "  ✅ $*"; }
fail() { FAIL=$((FAIL + 1)); REPORT+=("FAIL  $*"); log "  ❌ $*"; }

probe_svc() {
  local ns="$1" app="$2" path="$3"
  local name="regpr${RANDOM}"
  local code=""
  kubectl -n "$ns" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$ns" run "$name" --restart=Never --image=curlimages/curl:8.10.1 \
    --command -- curl -sS -m 12 -o /dev/null -w '%{http_code}' \
    "http://${app}.${ns}.svc.cluster.local${path}" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    phase="$(kubectl -n "$ns" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || echo Missing)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" || "$phase" == "Missing" ]] && break
    sleep 1
  done
  code="$(kubectl -n "$ns" logs "$name" 2>/dev/null | tr -d '\r\n' | grep -oE '^[0-9]{3}$' || true)"
  if [[ -z "$code" ]]; then
    code="$(kubectl -n "$ns" logs "$name" 2>/dev/null | tr -dc '0-9\n' | grep -oE '[0-9]{3}' | tail -1 || true)"
  fi
  kubectl -n "$ns" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  echo "${code:-000}"
}

check_app() {
  local name="$1"
  # shellcheck disable=SC1090
  eval "$(python3 "$ONBOARDING/scripts/app_env.py" "$name")"
  local ns="$APP_NS" app="$APP_NAME" argo="$APP_ARGO"
  local host="$APP_INGRESS_HOSTNAME"
  local live="${APP_LIVENESS:-/healthz}"
  local ready="${APP_READINESS:-/readyz}"

  log ""
  log "=== Pilot regression: ${name} ==="

  local sync health
  sync="$(kubectl -n argocd get application "$argo" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo Missing)"
  health="$(kubectl -n argocd get application "$argo" -o jsonpath='{.status.health.status}' 2>/dev/null || echo Missing)"
  if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
    ok "${name}: Argo CD Synced/Healthy"
  else
    fail "${name}: Argo CD sync=$sync health=$health (want Synced/Healthy)"
  fi

  local ready_n desired
  desired="$(kubectl -n "$ns" get deploy "$app" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  ready_n="$(kubectl -n "$ns" get deploy "$app" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  desired="${desired:-0}"
  ready_n="${ready_n:-0}"
  if [[ "$desired" -gt 0 && "$ready_n" == "$desired" ]]; then
    ok "${name}: Deployment Ready ${ready_n}/${desired}"
  else
    fail "${name}: Deployment Ready ${ready_n}/${desired}"
  fi

  local phase
  phase="$(kubectl -n "$ns" get pods -l "app.kubernetes.io/name=${app}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo Missing)"
  if [[ "$phase" == "Running" ]]; then
    ok "${name}: Pod Running"
  else
    fail "${name}: Pod not Running (${phase})"
  fi

  local code
  code="$(probe_svc "$ns" "$app" "$live")"
  if [[ "$code" == "200" ]]; then
    ok "${name}: healthz path ${live} HTTP 200 (Service)"
  else
    fail "${name}: healthz path ${live} HTTP ${code} (want 200)"
  fi
  code="$(probe_svc "$ns" "$app" "$ready")"
  if [[ "$code" == "200" ]]; then
    ok "${name}: readyz path ${ready} HTTP 200 (Service)"
  else
    fail "${name}: readyz path ${ready} HTTP ${code} (want 200)"
  fi

  # Ingress host probe (best-effort)
  code="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' -H "Host: ${host}" \
    "http://127.0.0.1:${INGRESS_PORT}${live}" 2>/dev/null || echo 000)"
  if [[ "$code" == "200" ]]; then
    ok "${name}: ingress ${host}${live} HTTP 200"
  else
    fail "${name}: ingress ${host}${live} HTTP ${code}"
  fi

  local np
  np="$(kubectl -n "$ns" get networkpolicy -l "app.kubernetes.io/name=${app}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$np" ]]; then
    np="$(kubectl -n "$ns" get networkpolicy "$app" -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
  fi
  if [[ -n "$np" ]]; then
    ok "${name}: NetworkPolicy active (${np})"
  else
    fail "${name}: NetworkPolicy missing"
  fi

  local img
  img="$(kubectl -n "$ns" get deploy "$app" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  if [[ "$img" == *:latest || "$img" == *git-pending* ]]; then
    fail "${name}: image not immutable (${img})"
  elif [[ -n "$img" ]]; then
    ok "${name}: image immutable-looking (${img##*/})"
  else
    fail "${name}: could not read image"
  fi
}

# --- main ---
kubectl config use-context "$CONTEXT" >/dev/null

log "=== Dual-pilot regression (k3d-${CLUSTER_NAME}) ==="

mapfile -t APPS < <(ls -1 "$ONBOARDING/apps"/*.yaml 2>/dev/null | xargs -n1 basename | sed 's/\.yaml$//')
if [[ ${#APPS[@]} -eq 0 ]]; then
  fail "no app definitions under onboarding/apps"
else
  ok "found ${#APPS[@]} onboarded app definition(s): ${APPS[*]}"
fi

# Require both known pilots
for required in ai-doc-assistant booknbook; do
  if [[ " ${APPS[*]} " == *" ${required} "* ]]; then
    ok "required pilot definition present: ${required}"
  else
    fail "required pilot definition missing: ${required}"
  fi
done

for app in "${APPS[@]}"; do
  check_app "$app"
done

log ""
log "============================================================"
log "Results: PASS=${PASS}  FAIL=${FAIL}"
log "============================================================"
for line in "${REPORT[@]}"; do
  log "$line"
done

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
