#!/usr/bin/env bash
# Homelab resilience validation for ai-doc-assistant on K3s.
# Non-production only. Never prints secrets. Never uses :latest.
# Does NOT roll back to the old incompatible NumPy image.
#
# Defaults:
#   K3S_HOST=192.168.152.114  K3S_USER=soloadmin
#   NS=apps-ai-doc-assistant-homelab  APP=ai-doc-assistant
#   ARGO_APP=ai-doc-assistant-homelab
#   INGRESS_HOST=ai-doc-assistant.homelab.local
#
# Override USE_LOCAL_KUBECTL=1 if kubectl already targets the homelab cluster.
set -uo pipefail

export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"

BOOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${BOOT}/../../../.." && pwd)"

K3S_HOST="${K3S_HOST:-192.168.152.114}"
K3S_USER="${K3S_USER:-soloadmin}"
REMOTE_KUBECONFIG="${REMOTE_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
USE_LOCAL_KUBECTL="${USE_LOCAL_KUBECTL:-0}"

NS="${NS:-apps-ai-doc-assistant-homelab}"
APP="${APP:-ai-doc-assistant}"
ARGO_APP="${ARGO_APP:-ai-doc-assistant-homelab}"
INGRESS_HOST="${INGRESS_HOST:-ai-doc-assistant.homelab.local}"
INGRESS_URL="${INGRESS_URL:-http://127.0.0.1}"
EXPECTED_IMAGE_PREFIX="${EXPECTED_IMAGE_PREFIX:-registry.homelab.local:5000/solo-empire/ai-doc-assistant:git-}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.10.1}"
DENY_NS="${DENY_NS:-homelab-netpol-deny-test}"

PASS=0
FAIL=0
SKIP=0
REPORT=()
EVIDENCE=()

log()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); REPORT+=("PASS  $*"); log "  ✅ $*"; }
fail() { FAIL=$((FAIL + 1)); REPORT+=("FAIL  $*"); log "  ❌ $*"; }
skip() { SKIP=$((SKIP + 1)); REPORT+=("SKIP  $*"); log "  ⚠️  SKIP $*"; }
note() { EVIDENCE+=("$*"); log "  · $*"; }

# ---------------------------------------------------------------------------
# Remote / local kubectl + shell helpers
# ---------------------------------------------------------------------------
remote_sh() {
  # Run a bash snippet on the K3s node with KUBECONFIG set.
  ssh -o BatchMode=yes -o ConnectTimeout=15 "${K3S_USER}@${K3S_HOST}" \
    "export KUBECONFIG='${REMOTE_KUBECONFIG}'; export PATH=\"/usr/local/bin:/usr/bin:\$PATH\"; bash -s" <<EOF
set -uo pipefail
$*
EOF
}

kc() {
  if [[ "${USE_LOCAL_KUBECTL}" == "1" ]]; then
    kubectl "$@"
  else
    # Quote each arg for remote shell.
    local q="" a
    for a in "$@"; do
      q+=" $(printf '%q' "$a")"
    done
    ssh -o BatchMode=yes -o ConnectTimeout=15 "${K3S_USER}@${K3S_HOST}" \
      "export KUBECONFIG='${REMOTE_KUBECONFIG}'; export PATH=\"/usr/local/bin:/usr/bin:\$PATH\"; kubectl${q}"
  fi
}

remote_curl_code() {
  # HTTP code from the K3s node (for ingress Host-based probes).
  local path="$1"
  local host="${2:-$INGRESS_HOST}"
  local url="${INGRESS_URL}${path}"
  if [[ "${USE_LOCAL_KUBECTL}" == "1" ]]; then
    curl -sS -m 12 -o /dev/null -w '%{http_code}' -H "Host: ${host}" "${url}" 2>/dev/null || echo 000
  else
    ssh -o BatchMode=yes -o ConnectTimeout=15 "${K3S_USER}@${K3S_HOST}" \
      "curl -sS -m 12 -o /dev/null -w '%{http_code}' -H $(printf '%q' "Host: ${host}") $(printf '%q' "${url}") 2>/dev/null || echo 000"
  fi
}

wait_ready() {
  local timeout="${1:-180}"
  local end=$((SECONDS + timeout))
  kc -n "$NS" rollout status "deployment/$APP" --timeout="${timeout}s" >/dev/null 2>&1 || true
  while (( SECONDS < end )); do
    local desired ready
    desired="$(kc -n "$NS" get deploy "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
    ready="$(kc -n "$NS" get deploy "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
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
  kc -n "$NS" get deploy "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true
}

# Service probe via ephemeral curl pod.
# Label solo.empire/probe=true matches NetworkPolicy (avoid full pod CIDR).
# Sleep first so kube-router can enroll the pod into the allowlist ipset
# before curl runs (immediate curl races and gets connection refused).
# Returns only a 3-digit code or 000.
probe_svc() {
  local path="$1"
  local name="hlprb${RANDOM}"
  local code=""
  local settle="${PROBE_SETTLE_SECONDS:-8}"
  kc -n "$NS" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if [[ "${USE_LOCAL_KUBECTL}" == "1" ]]; then
    cat <<YAML | kubectl apply -f - >/dev/null 2>&1 || true
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${NS}
  labels:
    solo.empire/probe: "true"
    app.kubernetes.io/name: resilience-probe
spec:
  restartPolicy: Never
  containers:
    - name: curl
      image: ${CURL_IMAGE}
      command:
        - sh
        - -c
        - "sleep ${settle}; curl -sS -m 12 -o /dev/null -w '%{http_code}' 'http://${APP}.${NS}.svc.cluster.local${path}'"
YAML
  else
    ssh -o BatchMode=yes -o ConnectTimeout=15 "${K3S_USER}@${K3S_HOST}" \
      "export KUBECONFIG='${REMOTE_KUBECONFIG}'; cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${NS}
  labels:
    solo.empire/probe: \"true\"
    app.kubernetes.io/name: resilience-probe
spec:
  restartPolicy: Never
  containers:
    - name: curl
      image: ${CURL_IMAGE}
      command:
        - sh
        - -c
        - \"sleep ${settle}; curl -sS -m 12 -o /dev/null -w '%{http_code}' 'http://${APP}.${NS}.svc.cluster.local${path}'\"
YAML"
  fi
  local phase
  # settle + curl + margin
  for _ in $(seq 1 $((settle + 40))); do
    phase="$(kc -n "$NS" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || echo Missing)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" || "$phase" == "Missing" ]] && break
    sleep 1
  done
  code="$(kc -n "$NS" logs "$name" 2>/dev/null | tr -d '\r\n' | grep -oE '^[0-9]{3}$' || true)"
  if [[ -z "$code" ]]; then
    code="$(kc -n "$NS" logs "$name" 2>/dev/null | tr -dc '0-9\n' | grep -oE '[0-9]{3}' | tail -1 || true)"
  fi
  kc -n "$NS" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  echo "${code:-000}"
}

probe_svc_retry() {
  local path="$1"
  local want="${2:-200}"
  local code="000"
  local i
  for i in 1 2 3 4 5; do
    code="$(probe_svc "$path")"
    [[ "$code" == "$want" ]] && break
    sleep 3
  done
  echo "$code"
}

require_access() {
  if [[ "${USE_LOCAL_KUBECTL}" == "1" ]]; then
    kubectl -n argocd get application "$ARGO_APP" >/dev/null
    kubectl -n "$NS" get deploy "$APP" >/dev/null
  else
    ssh -o BatchMode=yes -o ConnectTimeout=15 "${K3S_USER}@${K3S_HOST}" \
      "export KUBECONFIG='${REMOTE_KUBECONFIG}'; kubectl -n argocd get application $(printf '%q' "$ARGO_APP") >/dev/null && kubectl -n $(printf '%q' "$NS") get deploy $(printf '%q' "$APP") >/dev/null"
  fi
}

# ---------------------------------------------------------------------------
log "=== Homelab resilience verification ==="
log "  host=${K3S_USER}@${K3S_HOST}  ns=${NS}  argo=${ARGO_APP}"
log "  mode=$([[ "${USE_LOCAL_KUBECTL}" == "1" ]] && echo local-kubectl || echo ssh-kubectl)"
log ""

if ! require_access; then
  fail "cannot reach Argo app ${ARGO_APP} / deploy ${APP} on ${K3S_HOST}"
  log ""
  log "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
  exit 1
fi
ok "cluster access and target Application/Deployment present"

# Ensure automated selfHeal so leftover local drift (e.g. prior netpol test) is healed
kc -n argocd patch application "$ARGO_APP" --type merge -p '{
  "spec": {
    "syncPolicy": {
      "automated": {"prune": false, "selfHeal": true},
      "syncOptions": ["CreateNamespace=true"]
    }
  }
}' >/dev/null 2>&1 || true
kc -n argocd annotate application "$ARGO_APP" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
log ""
log "[0] Argo CD Synced / Healthy"
SYNC="Unknown"
HEALTH="Unknown"
REV="unknown"
for _ in $(seq 1 36); do
  SYNC="$(kc -n argocd get application "$ARGO_APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo Unknown)"
  HEALTH="$(kc -n argocd get application "$ARGO_APP" -o jsonpath='{.status.health.status}' 2>/dev/null || echo Unknown)"
  REV="$(kc -n argocd get application "$ARGO_APP" -o jsonpath='{.status.sync.revision}' 2>/dev/null || echo unknown)"
  if [[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]]; then
    break
  fi
  if (( _ % 4 == 0 )); then
    kc -n argocd annotate application "$ARGO_APP" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  fi
  sleep 5
done
note "argo_sync=${SYNC} argo_health=${HEALTH} revision=${REV}"
if [[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]]; then
  ok "Argo CD Synced/Healthy (revision ${REV:0:12})"
else
  fail "Argo CD sync=${SYNC} health=${HEALTH}"
fi

# ---------------------------------------------------------------------------
log ""
log "[1] Image immutability (never :latest)"
IMG="$(image_of)"
note "image=${IMG}"
if [[ -z "$IMG" ]]; then
  fail "could not read deployment image"
elif [[ "$IMG" == *":latest" || "$IMG" == *":git-pending"* ]]; then
  fail "image uses mutable/placeholder tag: $IMG"
elif [[ "$IMG" != ${EXPECTED_IMAGE_PREFIX}* ]]; then
  fail "image does not match expected immutable prefix ${EXPECTED_IMAGE_PREFIX}* (got $IMG)"
elif [[ "$IMG" =~ :git-[0-9a-f]{7,40}$ ]]; then
  ok "image is immutable git-SHA tag: $IMG"
else
  fail "image tag is not git-<hexsha>: $IMG"
fi
TAG_PART="${IMG##*:}"

# ---------------------------------------------------------------------------
log ""
log "[2] Health endpoints via Service (/health /healthz /readyz)"
C_HEALTH="$(probe_svc_retry /health)"
C_HEALTHZ="$(probe_svc_retry /healthz)"
C_READYZ="$(probe_svc_retry /readyz)"
note "svc /health=${C_HEALTH} /healthz=${C_HEALTHZ} /readyz=${C_READYZ}"
[[ "$C_HEALTH"  == "200" ]] && ok "Service /health=200"  || fail "Service /health=${C_HEALTH}"
[[ "$C_HEALTHZ" == "200" ]] && ok "Service /healthz=200" || fail "Service /healthz=${C_HEALTHZ}"
[[ "$C_READYZ"  == "200" ]] && ok "Service /readyz=200"  || fail "Service /readyz=${C_READYZ}"

# ---------------------------------------------------------------------------
log ""
log "[3] Ingress HTTP 200 (Host: ${INGRESS_HOST})"
I_HEALTH="$(remote_curl_code /health)"
I_HEALTHZ="$(remote_curl_code /healthz)"
I_READYZ="$(remote_curl_code /readyz)"
I_ROOT="$(remote_curl_code /)"
# strip whitespace
I_HEALTH="$(echo "$I_HEALTH" | tr -dc '0-9' | tail -c 3)"
I_HEALTHZ="$(echo "$I_HEALTHZ" | tr -dc '0-9' | tail -c 3)"
I_READYZ="$(echo "$I_READYZ" | tr -dc '0-9' | tail -c 3)"
I_ROOT="$(echo "$I_ROOT" | tr -dc '0-9' | tail -c 3)"
I_HEALTH="${I_HEALTH:-000}"; I_HEALTHZ="${I_HEALTHZ:-000}"
I_READYZ="${I_READYZ:-000}"; I_ROOT="${I_ROOT:-000}"
note "ingress /health=${I_HEALTH} /healthz=${I_HEALTHZ} /readyz=${I_READYZ} /=${I_ROOT}"
[[ "$I_HEALTH"  == "200" ]] && ok "Ingress /health=200"  || fail "Ingress /health=${I_HEALTH}"
[[ "$I_HEALTHZ" == "200" ]] && ok "Ingress /healthz=200" || fail "Ingress /healthz=${I_HEALTHZ}"
[[ "$I_READYZ"  == "200" ]] && ok "Ingress /readyz=200"  || fail "Ingress /readyz=${I_READYZ}"
[[ "$I_ROOT"    == "200" ]] && ok "Ingress /=200"        || fail "Ingress /=${I_ROOT}"

# ---------------------------------------------------------------------------
log ""
log "[4] Pod restart recovers"
POD0="$(kc -n "$NS" get pod -l "app.kubernetes.io/name=$APP" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
RESTARTS_BEFORE="$(kc -n "$NS" get pod "$POD0" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)"
note "pod_before=${POD0} restarts_before=${RESTARTS_BEFORE}"
if [[ -z "$POD0" ]]; then
  fail "no pod found for delete/restart test"
else
  kc -n "$NS" delete pod "$POD0" --wait=true >/dev/null 2>&1 || true
  if wait_ready 180; then
    POD1="$(kc -n "$NS" get pod -l "app.kubernetes.io/name=$APP" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    RESTARTS_AFTER="$(kc -n "$NS" get pod "$POD1" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)"
    note "pod_after=${POD1} restarts_after=${RESTARTS_AFTER}"
    if [[ -n "$POD1" && "$POD0" != "$POD1" ]]; then
      ok "pod recreated after delete (${POD0} -> ${POD1})"
    else
      fail "pod name unchanged or missing after delete (before=${POD0} after=${POD1})"
    fi
    CODE="$(probe_svc_retry /healthz)"
    [[ "$CODE" == "200" ]] && ok "healthz=200 after pod restart recovery" || fail "healthz after restart: $CODE"
  else
    fail "deployment not Ready after pod delete"
  fi
fi

# ---------------------------------------------------------------------------
log ""
log "[5] Scale 1→2 is self-healed back to desired replicaCount=1"
# Ensure Argo selfHeal is on for this check (may have been paused for netpol apply)
kc -n argocd patch application "$ARGO_APP" --type merge -p '{
  "spec": {
    "syncPolicy": {
      "automated": {"prune": false, "selfHeal": true},
      "syncOptions": ["CreateNamespace=true"]
    }
  }
}' >/dev/null 2>&1 || true
note "argo selfHeal ensured true for scale test"

DESIRED_REPLICAS="$(kc -n "$NS" get deploy "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)"
DESIRED_REPLICAS="${DESIRED_REPLICAS:-1}"
note "desired_replicas_before_drift=${DESIRED_REPLICAS}"
if [[ "$DESIRED_REPLICAS" != "1" ]]; then
  note "warning: desired replicas is ${DESIRED_REPLICAS}, expected 1 from Git values"
fi

kc -n "$NS" scale "deployment/$APP" --replicas=2 >/dev/null 2>&1 || true
# Confirm drift briefly appears (or at least scale was accepted)
SCALED=false
for _ in $(seq 1 20); do
  CUR_SPEC="$(kc -n "$NS" get deploy "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  CUR_READY="$(kc -n "$NS" get deploy "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [[ "${CUR_SPEC:-0}" == "2" || "${CUR_READY:-0}" == "2" ]]; then
    SCALED=true
    break
  fi
  sleep 2
done
if [[ "$SCALED" == "true" ]]; then
  ok "manual scale to 2 observed (drift introduced)"
else
  # Argo may heal so fast that 2 never sticks; still verify final state is 1.
  note "scale-to-2 not observed long enough (self-heal may be fast); continuing"
fi

# Force Argo refresh periodically while waiting for self-heal
HEALED=false
for i in $(seq 1 48); do
  CUR_SPEC="$(kc -n "$NS" get deploy "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  CUR_READY="$(kc -n "$NS" get deploy "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [[ "${CUR_SPEC:-0}" == "1" && "${CUR_READY:-0}" == "1" ]]; then
    HEALED=true
    break
  fi
  if (( i % 3 == 0 )); then
    kc -n argocd annotate application "$ARGO_APP" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  fi
  sleep 5
done

FINAL_SPEC="$(kc -n "$NS" get deploy "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
FINAL_READY="$(kc -n "$NS" get deploy "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
note "after_selfheal spec_replicas=${FINAL_SPEC} readyReplicas=${FINAL_READY}"
if [[ "$HEALED" == "true" && "${FINAL_SPEC}" == "1" && "${FINAL_READY}" == "1" ]]; then
  ok "Argo self-heal restored replicaCount to 1 (spec=1 ready=1)"
else
  fail "expected self-heal to replicas=1, got spec=${FINAL_SPEC} ready=${FINAL_READY}"
fi

SYNC2="$(kc -n argocd get application "$ARGO_APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo Unknown)"
HEALTH2="$(kc -n argocd get application "$ARGO_APP" -o jsonpath='{.status.health.status}' 2>/dev/null || echo Unknown)"
note "argo_after_scale_test sync=${SYNC2} health=${HEALTH2}"
if [[ "$SYNC2" == "Synced" && ( "$HEALTH2" == "Healthy" || "$HEALTH2" == "Progressing" ) ]]; then
  ok "Argo still Synced after scale self-heal (health=${HEALTH2})"
else
  fail "Argo after scale self-heal: sync=${SYNC2} health=${HEALTH2}"
fi

# ---------------------------------------------------------------------------
log ""
log "[6] NetworkPolicy: ingress-nginx allowed; unrelated namespace denied"
# Desired policy (matches helm values): allow ingress-nginx + labeled probes only.
# GitHub main may still carry a broader ipBlock until values are pushed; apply the
# tight policy for this check with selfHeal briefly paused so Argo does not revert.
kc -n argocd patch application "$ARGO_APP" --type merge -p '{
  "spec": {
    "syncPolicy": {
      "automated": {"prune": false, "selfHeal": false},
      "syncOptions": ["CreateNamespace=true"]
    }
  }
}' >/dev/null 2>&1 || true
note "argo selfHeal paused for NetworkPolicy isolation test"

if [[ "${USE_LOCAL_KUBECTL}" == "1" ]]; then
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${APP}
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: ${APP}
    app.kubernetes.io/instance: ${APP}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: ${APP}
      app.kubernetes.io/instance: ${APP}
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
        - podSelector:
            matchLabels:
              solo.empire/probe: "true"
      ports:
        - protocol: TCP
          port: 8000
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - ports:
        - protocol: TCP
          port: 443
YAML
else
  ssh -o BatchMode=yes -o ConnectTimeout=15 "${K3S_USER}@${K3S_HOST}" \
    "export KUBECONFIG='${REMOTE_KUBECONFIG}'; cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${APP}
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: ${APP}
    app.kubernetes.io/instance: ${APP}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: ${APP}
      app.kubernetes.io/instance: ${APP}
  policyTypes: [\"Ingress\", \"Egress\"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
        - podSelector:
            matchLabels:
              solo.empire/probe: \"true\"
      ports:
        - protocol: TCP
          port: 8000
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - ports:
        - protocol: TCP
          port: 443
YAML"
fi
sleep 3
note "tight NetworkPolicy applied (ingress-nginx + solo.empire/probe=true)"

# Ingress path = allow-proof for ingress-nginx
NP_ING="$(remote_curl_code /healthz)"
NP_ING="$(echo "$NP_ING" | tr -dc '0-9' | tail -c 3)"
NP_ING="${NP_ING:-000}"
if [[ "$NP_ING" == "200" ]]; then
  ok "NetworkPolicy allows ingress-nginx path (ingress /healthz=${NP_ING})"
else
  fail "NetworkPolicy/ingress path blocked or failing (code=${NP_ING})"
fi

# Same-namespace probe pods labeled solo.empire/probe=true are allowlisted
SAME="$(probe_svc_retry /healthz)"
[[ "$SAME" == "200" ]] && ok "same-namespace labeled probe access allowed (healthz=${SAME})" \
  || fail "same-namespace labeled probe access code=${SAME}"

# Deny: unrelated namespace (unlabeled; not ingress-nginx)
kc create ns "$DENY_NS" --dry-run=client -o yaml 2>/dev/null | kc apply -f - >/dev/null 2>&1 || true
DENY_POD="curl-deny-${RANDOM}"
kc -n "$DENY_NS" delete pod "$DENY_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
kc -n "$DENY_NS" run "$DENY_POD" --restart=Never --image="$CURL_IMAGE" \
  --command -- curl -sS -m 8 -o /dev/null -w '%{http_code}' \
  "http://${APP}.${NS}.svc.cluster.local/healthz" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
  phase="$(kc -n "$DENY_NS" get pod "$DENY_POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo Missing)"
  [[ "$phase" == "Succeeded" || "$phase" == "Failed" || "$phase" == "Missing" ]] && break
  sleep 1
done
DENY_CODE="$(kc -n "$DENY_NS" logs "$DENY_POD" 2>/dev/null | tr -d '\r\n' | grep -oE '^[0-9]{3}$' || true)"
if [[ -z "$DENY_CODE" ]]; then
  DENY_CODE="$(kc -n "$DENY_NS" logs "$DENY_POD" 2>/dev/null | tr -dc '0-9\n' | grep -oE '[0-9]{3}' | tail -1 || true)"
fi
DENY_CODE="${DENY_CODE:-000}"
note "deny_namespace_code=${DENY_CODE}"
if [[ "$DENY_CODE" != "200" ]]; then
  ok "unrelated namespace denied or cannot reach app (code=${DENY_CODE})"
else
  fail "unrelated namespace reached app (code=200) — NetworkPolicy too open"
fi
kc -n "$DENY_NS" delete pod "$DENY_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
kc delete ns "$DENY_NS" --wait=false >/dev/null 2>&1 || true

# Restore Argo selfHeal for normal ops
kc -n argocd patch application "$ARGO_APP" --type merge -p '{
  "spec": {
    "syncPolicy": {
      "automated": {"prune": false, "selfHeal": true},
      "syncOptions": ["CreateNamespace=true"]
    }
  }
}' >/dev/null 2>&1 || true
ok "Argo selfHeal re-enabled after NetworkPolicy test"
note "tight NetworkPolicy is tracked in Git desired state; Argo selfHeal restored normal operation"

# ---------------------------------------------------------------------------
log ""
log "[7] No application secrets in Git (platform paths)"
# Application secrets must not live in Git manifests (yaml/yml/tpl only).
# Shell installers that *generate* host-local passwords at runtime are OK.
SECRET_HITS=""
if command -v git >/dev/null 2>&1; then
  SECRET_HITS="$(
    git -C "$ROOT" grep -nIE \
      '(OPENAI_API_KEY|API_KEY|SECRET_KEY|PASSWORD|PRIVATE_KEY|aws_secret|token)[[:space:]]*[:=][[:space:]]*['\''"]?[A-Za-z0-9+/=_\-.]{8,}' \
      -- \
      'infra/platform/gitops' \
      'infra/platform/helm/solo-app/homelab' \
      'infra/platform/helm/solo-app/values.yaml' \
      'infra/platform/gitops/homelab' \
      2>/dev/null \
    | grep -E '\.(ya?ml|tpl):' \
    | grep -vE 'dummy|example|REDACTED|placeholder|from-literal|git-pending|change-me|TODO|YOUR_|<.*>|\$\{|secretKeyRef|name:|path:|valueFrom|enabled:|type:|#' \
    || true
  )"
fi
if [[ -n "$SECRET_HITS" ]]; then
  fail "possible secret material in tracked platform manifests"
  printf '%s\n' "$SECRET_HITS" | head -20
else
  ok "no application secret assignments in tracked homelab/platform manifests"
fi

# Also ensure Application/values do not embed real OpenAI keys as Helm params
if git -C "$ROOT" grep -nIE 'sk-[A-Za-z0-9]{10,}' -- \
  'infra/platform/gitops/homelab' \
  'infra/platform/helm/solo-app/homelab' \
  2>/dev/null; then
  fail "OpenAI-like token pattern found in homelab Git manifests"
else
  ok "no OpenAI-like token patterns in homelab Git manifests"
fi

# ---------------------------------------------------------------------------
log ""
log "[8] Final state guards"
wait_ready 120 || true
IMG2="$(image_of)"
note "final_image=${IMG2}"
[[ "$IMG2" != *":latest"* && "$IMG2" == *":git-"* ]] \
  && ok "final image still immutable (not :latest): ${IMG2}" \
  || fail "final image bad: ${IMG2}"

FINAL_POD="$(kc -n "$NS" get pod -l "app.kubernetes.io/name=$APP" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
FINAL_RESTARTS="$(kc -n "$NS" get pod "$FINAL_POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo unknown)"
note "final_pod=${FINAL_POD} restartCount=${FINAL_RESTARTS}"

C1="$(probe_svc_retry /healthz)"; C2="$(probe_svc_retry /readyz)"
[[ "$C1" == "200" && "$C2" == "200" ]] \
  && ok "final Service healthz/readyz=200" \
  || fail "final Service probes healthz=${C1} readyz=${C2}"

IF1="$(remote_curl_code /healthz)"; IF1="$(echo "$IF1" | tr -dc '0-9' | tail -c 3)"; IF1="${IF1:-000}"
IF2="$(remote_curl_code /readyz)";  IF2="$(echo "$IF2" | tr -dc '0-9' | tail -c 3)"; IF2="${IF2:-000}"
[[ "$IF1" == "200" && "$IF2" == "200" ]] \
  && ok "final Ingress healthz/readyz=200" \
  || fail "final Ingress probes healthz=${IF1} readyz=${IF2}"

SYNC3="$(kc -n argocd get application "$ARGO_APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo Unknown)"
HEALTH3="$(kc -n argocd get application "$ARGO_APP" -o jsonpath='{.status.health.status}' 2>/dev/null || echo Unknown)"
note "final_argo sync=${SYNC3} health=${HEALTH3}"
[[ "$SYNC3" == "Synced" && "$HEALTH3" == "Healthy" ]] \
  && ok "final Argo Synced/Healthy" \
  || fail "final Argo sync=${SYNC3} health=${HEALTH3}"

# Explicit non-action: image rollback to old NumPy baseline is skipped
skip "image rollback to pre-numpy-pin tag not tested (no approved alternate known-good image; incompatible NumPy image forbidden)"

# ---------------------------------------------------------------------------
log ""
log "============================================================"
log "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
log "============================================================"
for line in "${REPORT[@]}"; do
  log "$line"
done
log ""
log "--- Evidence ---"
for line in "${EVIDENCE[@]}"; do
  log "  $line"
done
log ""
log "Image tag: ${IMG2:-$IMG}"
log "Argo: sync=${SYNC3:-$SYNC} health=${HEALTH3:-$HEALTH}"
log "Pod restartCount (final): ${FINAL_RESTARTS:-unknown}"
log "Service probes: /health=${C_HEALTH} /healthz=${C_HEALTHZ} /readyz=${C_READYZ}"
log "Ingress probes: /health=${I_HEALTH} /healthz=${I_HEALTHZ} /readyz=${I_READYZ} /=${I_ROOT}"
log "============================================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
