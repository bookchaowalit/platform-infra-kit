#!/usr/bin/env bash
# Repeatable resilience + data-readiness checks for a local pilot on k3d-solo-dev.
# Defaults to ai-doc-assistant; override NS/APP/ARGO_APP for booknbook (or others).
# Uses dummy secrets only. Never prints secret values.
set -uo pipefail

export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"
BOOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-solo-dev}"
CONTEXT="k3d-${CLUSTER_NAME}"
NS="${NS:-apps-ai-doc-assistant-dev}"
APP="${APP:-ai-doc-assistant}"
ARGO_APP="${ARGO_APP:-ai-doc-assistant-dev}"
PASS=0
FAIL=0
SKIP=0
REPORT=()

log()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); REPORT+=("PASS  $*"); log "  ✅ $*"; }
fail() { FAIL=$((FAIL+1)); REPORT+=("FAIL  $*"); log "  ❌ $*"; }
skip() { SKIP=$((SKIP+1)); REPORT+=("SKIP  $*"); log "  ⚠️  SKIP $*"; }

require_ctx() {
  kubectl config use-context "$CONTEXT" >/dev/null
  kubectl -n argocd get application "$ARGO_APP" >/dev/null
  kubectl -n "$NS" get deploy "$APP" >/dev/null
}

wait_ready() {
  local timeout="${1:-180}"
  local end=$((SECONDS + timeout))
  # rollout status can succeed while old pods still terminate
  kubectl -n "$NS" rollout status "deployment/$APP" --timeout="${timeout}s" >/dev/null 2>&1 || true
  while (( SECONDS < end )); do
    local desired ready
    desired="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
    ready="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    desired="${desired:-0}"
    ready="${ready:-0}"
    if [[ "$desired" -gt 0 && "$ready" == "$desired" ]]; then
      return 0
    fi
    sleep 3
  done
  return 1
}

image_of() {
  kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}'
}

# Return only a 3-digit HTTP code (or 000). Avoid matching digits from pod names.
probe_svc() {
  local path="$1"
  local name="curlpr${RANDOM}"
  local code=""
  kubectl -n "$NS" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if kubectl -n "$NS" run "$name" --restart=Never --image=curlimages/curl:8.10.1 \
      --command -- curl -sS -m 12 -o /dev/null -w '%{http_code}' \
      "http://${APP}.${NS}.svc.cluster.local${path}" >/dev/null 2>&1; then
    :
  fi
  # Wait until the one-shot pod finishes
  for _ in $(seq 1 30); do
    phase="$(kubectl -n "$NS" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || echo Missing)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" || "$phase" == "Missing" ]] && break
    sleep 1
  done
  code="$(kubectl -n "$NS" logs "$name" 2>/dev/null | tr -d '\r\n' | grep -oE '^[0-9]{3}$' || true)"
  if [[ -z "$code" ]]; then
    code="$(kubectl -n "$NS" logs "$name" 2>/dev/null | tr -dc '0-9\n' | grep -oE '[0-9]{3}' | tail -1 || true)"
  fi
  kubectl -n "$NS" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  echo "${code:-000}"
}

argo_disable_autosync() {
  kubectl -n argocd patch application "$ARGO_APP" --type json -p='[
    {"op":"remove","path":"/spec/syncPolicy"}
  ]' >/dev/null 2>&1 || \
  kubectl -n argocd patch application "$ARGO_APP" --type merge \
    -p '{"spec":{"syncPolicy":null}}' >/dev/null 2>&1 || true
}

argo_enable_autosync() {
  kubectl -n argocd patch application "$ARGO_APP" --type merge -p '{
    "spec": {
      "syncPolicy": {
        "automated": {"prune": true, "selfHeal": true},
        "syncOptions": ["CreateNamespace=true", "ServerSideApply=true"]
      }
    }
  }' >/dev/null
}

# ---------------------------------------------------------------------------
log "=== Pilot resilience verification ($CONTEXT / $NS) ==="
require_ctx

log ""
log "[0] Image immutability"
IMG="$(image_of)"
log "  image=$IMG"
if [[ "$IMG" == *":latest" || "$IMG" == *":0.1.0-local" ]]; then
  fail "image uses mutable/placeholder tag: $IMG"
else
  ok "image is not :latest / 0.1.0-local"
fi

# ---------------------------------------------------------------------------
log ""
log "[1] Pod restart + deployment rollout"
POD0="$(kubectl -n "$NS" get pod -l "app.kubernetes.io/name=$APP" -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$NS" delete pod "$POD0" --wait=true >/dev/null
if wait_ready 180; then
  POD1="$(kubectl -n "$NS" get pod -l "app.kubernetes.io/name=$APP" -o jsonpath='{.items[0].metadata.name}')"
  if [[ "$POD0" != "$POD1" ]]; then
    ok "pod recreated after delete ($POD0 -> $POD1)"
  else
    fail "pod name unchanged after delete"
  fi
else
  fail "deployment not Ready after pod delete"
fi
CODE="$(probe_svc /healthz)"
[[ "$CODE" == "200" ]] && ok "healthz=200 after pod delete recovery" || fail "healthz after restart: $CODE"

kubectl -n "$NS" rollout restart "deployment/$APP" >/dev/null
if wait_ready 180; then
  # Brief settle so Service endpoints catch up after restart
  sleep 5
  CODE="000"
  for _ in 1 2 3 4 5; do
    CODE="$(probe_svc /readyz)"
    [[ "$CODE" == "200" ]] && break
    sleep 3
  done
  [[ "$CODE" == "200" ]] && ok "readyz=200 after rollout restart" || fail "readyz after rollout: $CODE"
else
  fail "deployment not Ready after rollout restart"
fi

# ---------------------------------------------------------------------------
log ""
log "[2] Scale 1 -> 2 and both Ready"
HPA_EXISTS=false
if kubectl -n "$NS" get hpa "$APP" >/dev/null 2>&1; then
  HPA_EXISTS=true
  kubectl -n "$NS" patch hpa "$APP" --type merge -p '{"spec":{"minReplicas":2,"maxReplicas":2}}' >/dev/null
fi
kubectl -n "$NS" scale "deployment/$APP" --replicas=2 >/dev/null
for i in $(seq 1 40); do
  R="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.status.readyReplicas}')"
  [[ "${R:-0}" == "2" ]] && break
  sleep 5
done
R="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.status.readyReplicas}')"
[[ "${R:-0}" == "2" ]] && ok "2 replicas Ready" || fail "expected 2 ready replicas, got ${R:-0}"
POD_COUNT="$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=$APP" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[[ "$POD_COUNT" -ge 2 ]] && ok "running pod count >= 2 ($POD_COUNT)" || fail "running pod count $POD_COUNT"
# HPA still exists
if [[ "$HPA_EXISTS" == "true" ]]; then
  ok "HPA present and temporarily pinned min=max=2 for scale test"
else
  skip "HPA not found"
fi

# ---------------------------------------------------------------------------
log ""
log "[3] Delete one Pod; Kubernetes recreates"
POD_A="$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=$APP" -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$NS" delete pod "$POD_A" --wait=true >/dev/null
wait_ready 180 || true
for i in $(seq 1 30); do
  R="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.status.readyReplicas}')"
  [[ "${R:-0}" == "2" ]] && break
  sleep 5
done
R="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.status.readyReplicas}')"
if [[ "${R:-0}" == "2" ]] && ! kubectl -n "$NS" get pod "$POD_A" >/dev/null 2>&1; then
  ok "deleted pod recreated; still 2 Ready"
else
  fail "after single-pod delete: readyReplicas=${R:-0}"
fi

# ---------------------------------------------------------------------------
log ""
log "[4] Argo CD self-heal after manual Deployment drift"
DESIRED_IMG="$(image_of)"
DESIRED_TEAM="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.metadata.labels.solo\.empire/team}')"
# Drift a managed label Argo owns (solo.empire/team comes from chart values)
kubectl -n "$NS" label deploy "$APP" "solo.empire/team=drifted-by-resilience-test" --overwrite >/dev/null
HEALED=false
for i in $(seq 1 48); do
  TEAM="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.metadata.labels.solo\.empire/team}' 2>/dev/null || true)"
  if [[ "$TEAM" == "$DESIRED_TEAM" || "$TEAM" == "product" ]]; then
    HEALED=true
    break
  fi
  if (( i % 3 == 0 )); then
    kubectl -n argocd annotate application "$ARGO_APP" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  fi
  sleep 5
done
if [[ "$HEALED" == "true" ]]; then
  ok "Argo CD self-healed label drift (solo.empire/team restored to ${DESIRED_TEAM:-product})"
else
  # Fallback: image drift is always managed
  kubectl -n "$NS" set image "deployment/$APP" "${APP}=${DESIRED_IMG%-*}:git-drift-invalid" >/dev/null 2>&1 || \
    kubectl -n "$NS" set image "deployment/$APP" "${APP}=invalid.local/none:git-drift" >/dev/null
  for i in $(seq 1 36); do
    CUR="$(image_of)"
    if [[ "$CUR" == "$DESIRED_IMG" ]]; then HEALED=true; break; fi
    kubectl -n argocd annotate application "$ARGO_APP" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
    sleep 5
  done
  if [[ "$HEALED" == "true" ]]; then
    ok "Argo CD self-healed image drift back to desired immutable tag"
  else
    fail "Argo CD did not self-heal label/image drift within timeout"
  fi
fi
SYNC="$(kubectl -n argocd get application "$ARGO_APP" -o jsonpath='{.status.sync.status}')"
HEALTH="$(kubectl -n argocd get application "$ARGO_APP" -o jsonpath='{.status.health.status}')"
[[ "$HEALTH" == "Healthy" || "$HEALTH" == "Progressing" ]] \
  && ok "Argo health=$HEALTH sync=$SYNC after self-heal test" \
  || fail "Argo after self-heal: sync=$SYNC health=$HEALTH"
wait_ready 120 || true

# ---------------------------------------------------------------------------
log ""
log "[5] Rollback using older immutable image tag"
TAG_PART="${DESIRED_IMG##*:}"
REPO_PART="${DESIRED_IMG%:*}"
OLD_TAG="git-rollback-prev"

# Pin HPA back so rollback uses 1 replica for cleaner history
if [[ "$HPA_EXISTS" == "true" ]]; then
  kubectl -n "$NS" patch hpa "$APP" --type merge -p '{"spec":{"minReplicas":1,"maxReplicas":2}}' >/dev/null
fi
kubectl -n "$NS" scale "deployment/$APP" --replicas=1 >/dev/null 2>&1 || true
wait_ready 120 || true

if docker image inspect "localhost:5111/solo-empire/ai-doc-assistant:${TAG_PART}" >/dev/null 2>&1; then
  docker tag "localhost:5111/solo-empire/ai-doc-assistant:${TAG_PART}" \
    "localhost:5111/solo-empire/ai-doc-assistant:${OLD_TAG}"
  if docker push "localhost:5111/solo-empire/ai-doc-assistant:${OLD_TAG}" >/dev/null 2>&1; then
    ok "pushed alternate immutable tag ${OLD_TAG} to local registry"
  else
    skip "could not push ${OLD_TAG} to local registry"
    OLD_TAG=""
  fi
else
  skip "host docker lacks ${TAG_PART} for retag"
  OLD_TAG=""
fi

if [[ -n "$OLD_TAG" ]]; then
  # Pause Argo so manual rollback is observable
  argo_disable_autosync
  sleep 2
  kubectl -n "$NS" set image "deployment/$APP" "${APP}=${REPO_PART}:${OLD_TAG}" >/dev/null
  # Do not require full Ready if pull is slow; check image field
  for i in $(seq 1 24); do
    CUR="$(image_of)"
    [[ "$CUR" == *":${OLD_TAG}" ]] && break
    sleep 5
  done
  CUR="$(image_of)"
  if [[ "$CUR" == *":${OLD_TAG}" ]]; then
    ok "deployed alternate immutable tag ${OLD_TAG}"
  else
    fail "expected image ...:${OLD_TAG}, got $CUR"
  fi
  # Rollout undo restores previous revision (git-sha tag)
  kubectl -n "$NS" rollout undo "deployment/$APP" >/dev/null
  for i in $(seq 1 24); do
    CUR="$(image_of)"
    [[ "$CUR" == *":${TAG_PART}" || "$CUR" == "$DESIRED_IMG" ]] && break
    sleep 5
  done
  wait_ready 180 || true
  CUR="$(image_of)"
  if [[ "$CUR" == *":${TAG_PART}" || "$CUR" == "$DESIRED_IMG" ]]; then
    ok "rollout undo restored prior immutable image tag"
  else
    fail "after undo image is $CUR (wanted *:${TAG_PART})"
  fi
  CODE="$(probe_svc /healthz)"
  [[ "$CODE" == "200" ]] && ok "healthz=200 after rollback" || fail "healthz after rollback: $CODE"
  # Re-enable Argo auto-sync / self-heal
  argo_enable_autosync
  ok "Argo automated sync/selfHeal re-enabled"
else
  argo_enable_autosync
fi

# ---------------------------------------------------------------------------
log ""
log "[6] Secret rotation (dummy values only)"
kubectl -n "$NS" create secret generic ai-doc-assistant-openai \
  --from-literal=OPENAI_API_KEY='dummy-openai-key-rotation-v1-not-real' \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
H1="$(kubectl -n "$NS" get secret ai-doc-assistant-openai -o jsonpath='{.data.OPENAI_API_KEY}' | sha256sum | awk '{print $1}')"
kubectl -n "$NS" create secret generic ai-doc-assistant-openai \
  --from-literal=OPENAI_API_KEY='dummy-openai-key-rotation-v2-not-real' \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
H2="$(kubectl -n "$NS" get secret ai-doc-assistant-openai -o jsonpath='{.data.OPENAI_API_KEY}' | sha256sum | awk '{print $1}')"
if [[ -n "$H1" && -n "$H2" && "$H1" != "$H2" ]]; then
  ok "secret rotation changed secret data (sha256 differs; values not printed)"
else
  fail "secret rotation hash check failed"
fi
if kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1; then
  ok "External Secrets CRD installed (rotation demo uses K8s Secret; ESO store optional)"
else
  skip "ExternalSecret CRD missing"
fi

# ---------------------------------------------------------------------------
log ""
log "[7] NetworkPolicy allow/deny"
CODE="$(probe_svc /healthz)"
[[ "$CODE" == "200" ]] && ok "same-namespace Service access allowed (healthz=$CODE)" || fail "same-namespace access code=$CODE"

ING_CODE="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' -H 'Host: ai-doc-assistant.dev.local' http://127.0.0.1:18080/healthz 2>/dev/null || echo 000)"
[[ "$ING_CODE" == "200" ]] && ok "ingress path can access app (healthz=$ING_CODE)" || fail "ingress path code=$ING_CODE"

kubectl create ns pilot-netpol-deny-test --dry-run=client -o yaml | kubectl apply -f - >/dev/null
DENY_RAW="$(kubectl -n pilot-netpol-deny-test run "curl-deny-${RANDOM}" --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 -- \
  curl -sS -m 8 -o /dev/null -w '%{http_code}' \
  "http://${APP}.${NS}.svc.cluster.local/healthz" 2>&1 || true)"
DENY_CODE="$(printf '%s' "$DENY_RAW" | grep -oE '[0-9]{3}' | tail -1 || true)"
DENY_CODE="${DENY_CODE:-000}"
if [[ "$DENY_CODE" != "200" ]]; then
  ok "unrelated namespace denied or cannot reach app (code=$DENY_CODE)"
else
  fail "unrelated namespace reached app (code=200)"
fi
kubectl delete ns pilot-netpol-deny-test --wait=false >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
log ""
log "[8] Chroma data-loss after Pod restart"
POD_C="$(kubectl -n "$NS" get pod -l "app.kubernetes.io/name=$APP" -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$NS" exec "$POD_C" -- sh -c 'echo marker-v1 > /app/chroma-data/RESILIENCE_MARKER' >/dev/null 2>&1 || true
MARK_BEFORE="$(kubectl -n "$NS" exec "$POD_C" -- sh -c 'cat /app/chroma-data/RESILIENCE_MARKER 2>/dev/null || echo MISSING')"
kubectl -n "$NS" delete pod "$POD_C" --wait=true >/dev/null
wait_ready 180 || true
POD_D="$(kubectl -n "$NS" get pod -l "app.kubernetes.io/name=$APP" -o jsonpath='{.items[0].metadata.name}')"
MARK_AFTER="$(kubectl -n "$NS" exec "$POD_D" -- sh -c 'cat /app/chroma-data/RESILIENCE_MARKER 2>/dev/null || echo MISSING')"
if [[ "$MARK_AFTER" == "MISSING" ]]; then
  ok "Chroma emptyDir data lost after pod restart (marker MISSING) — demo-only persistence"
else
  fail "marker still present after restart: $MARK_AFTER"
fi

# ---------------------------------------------------------------------------
log ""
log "[9] Final guards"
IMG2="$(image_of)"
[[ "$IMG2" != *":latest"* ]] && ok "final image still not :latest" || fail "final image is latest"
C1="$(probe_svc /healthz)"; C2="$(probe_svc /readyz)"
[[ "$C1" == "200" && "$C2" == "200" ]] && ok "final healthz/readyz=200" || fail "final probes healthz=$C1 readyz=$C2"
# Ensure Argo sync policy restored
argo_enable_autosync
ok "Argo automated policy ensured enabled"
# Scan git-tracked platform paths for secret-like assignments (exclude docs/scripts comments)
if git -C "$(cd "$BOOT/../../../.." && pwd)" grep -nIE 'OPENAI_API_KEY[[:space:]]*=[[:space:]]*[^$].{8,}' \
  -- 'infra/platform/gitops' 'infra/platform/bootstrap/local/*.yaml' 'infra/platform/bootstrap/local/*.tpl' 2>/dev/null \
  | grep -vE 'dummy|example|REDACTED|from-literal|create-pilot|#' ; then
  fail "possible secret assignment in tracked manifests"
else
  ok "no real secret assignments in tracked pilot manifests"
fi

# ---------------------------------------------------------------------------
log ""
log "============================================================"
log "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
log "============================================================"
for line in "${REPORT[@]}"; do
  log "$line"
done

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
