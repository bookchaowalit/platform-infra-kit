#!/usr/bin/env bash
# Business smoke test for booknbook pilot (k3d-solo-dev only).
# - homepage returns 200
# - locale middleware works
# - static assets load
# - probe paths are not redirected
set -uo pipefail

export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"
CLUSTER_NAME="${CLUSTER_NAME:-solo-dev}"
CONTEXT="k3d-${CLUSTER_NAME}"
NS="${NS:-apps-booknbook-dev}"
APP="${APP:-booknbook}"
HOST="${HOST:-booknbook.dev.local}"
INGRESS_PORT="${INGRESS_PORT:-18080}"
BASE="http://127.0.0.1:${INGRESS_PORT}"

PASS=0
FAIL=0
REPORT=()

log()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); REPORT+=("PASS  $*"); log "  ✅ $*"; }
fail() { FAIL=$((FAIL + 1)); REPORT+=("FAIL  $*"); log "  ❌ $*"; }

# curl with Host header; prints "CODE|headers|body_snip"
req() {
  local path="$1"
  local follow="${2:-}"  # empty or -L
  local tmp headers body code
  tmp="$(mktemp)"
  headers="$(mktemp)"
  # shellcheck disable=SC2086
  code="$(curl -sS -m 15 ${follow} -D "$headers" -o "$tmp" -w '%{http_code}' \
    -H "Host: ${HOST}" "${BASE}${path}" 2>/dev/null || echo 000)"
  body="$(head -c 400 "$tmp" 2>/dev/null | tr -d '\000' | tr '\n' ' ')"
  # emit code, location header if any, body snip on separate tracked vars via files
  printf '%s\n' "$code" >"${tmp}.code"
  grep -i '^Location:' "$headers" 2>/dev/null | head -1 | tr -d '\r' >"${tmp}.loc" || true
  printf '%s' "$body" >"${tmp}.body"
  echo "$tmp"
}

cleanup_tmp() {
  local t="$1"
  rm -f "$t" "$t.code" "$t.loc" "$t.body" 2>/dev/null || true
}

kubectl config use-context "$CONTEXT" >/dev/null

log "=== booknbook business smoke (Host: ${HOST}) ==="

# 0) App is up
if kubectl -n "$NS" get deploy "$APP" >/dev/null 2>&1; then
  ok "deployment ${APP} exists in ${NS}"
else
  fail "deployment ${APP} missing in ${NS}"
  log "Results: PASS=${PASS} FAIL=${FAIL}"
  exit 1
fi

# 1) Homepage returns 200 (may redirect to locale first without -L)
t="$(req /)"
code="$(cat "${t}.code")"
loc="$(cat "${t}.loc" 2>/dev/null || true)"
if [[ "$code" == "200" ]]; then
  ok "homepage / HTTP 200"
elif [[ "$code" == "307" || "$code" == "308" || "$code" == "302" || "$code" == "301" ]]; then
  ok "homepage / redirects (${code}) for locale middleware: ${loc:-no Location}"
  t2="$(req / -L)"
  code2="$(cat "${t2}.code")"
  if [[ "$code2" == "200" ]]; then
    ok "homepage follow-redirect HTTP 200"
  else
    fail "homepage follow-redirect HTTP ${code2}"
  fi
  cleanup_tmp "$t2"
else
  fail "homepage / HTTP ${code} (want 200 or locale redirect)"
fi
cleanup_tmp "$t"

# 2) Locale middleware works — default locale path serves content
for locale_path in /th /en /ja; do
  t="$(req "$locale_path")"
  code="$(cat "${t}.code")"
  body="$(cat "${t}.body" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    ok "locale path ${locale_path} HTTP 200"
  else
    fail "locale path ${locale_path} HTTP ${code}"
  fi
  cleanup_tmp "$t"
done

# Root without locale should redirect into a known locale, not loop forever
t="$(req /)"
code="$(cat "${t}.code")"
loc="$(cat "${t}.loc" 2>/dev/null || true)"
if [[ "$code" =~ ^30[1278]$ ]]; then
  if echo "$loc" | grep -qiE '/(th|en|ja)(/|$)'; then
    ok "locale middleware redirects / → locale (${loc})"
  else
    # Some Next versions rewrite without Location on 200 after internal rewrite
    fail "locale redirect Location not a locale path: ${loc:-empty}"
  fi
elif [[ "$code" == "200" ]]; then
  ok "locale middleware: / served 200 (rewrite or cookie default)"
else
  fail "locale middleware unexpected code ${code}"
fi
cleanup_tmp "$t"

# 3) Static assets load — discover a _next static path from HTML or use known public asset
t="$(req /th -L)"
body="$(cat "${t}.body" 2>/dev/null || true)"
code="$(cat "${t}.code")"
asset=""
if [[ "$code" == "200" ]]; then
  asset="$(printf '%s' "$body" | tr -d '\000' | grep -oE '/_next/static/[^\"'\'' ]+' | head -1 || true)"
fi
cleanup_tmp "$t"

if [[ -n "$asset" ]]; then
  t="$(req "$asset")"
  code="$(cat "${t}.code")"
  if [[ "$code" == "200" ]]; then
    ok "static asset ${asset} HTTP 200"
  else
    fail "static asset ${asset} HTTP ${code}"
  fi
  cleanup_tmp "$t"
else
  # Fallback: favicon or any public file — probe common Next paths via Service
  name="smokeasset${RANDOM}"
  kubectl -n "$NS" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$NS" run "$name" --restart=Never --image=curlimages/curl:8.10.1 \
    --command -- sh -c \
    "html=\$(curl -sS -m 12 http://${APP}.${NS}.svc.cluster.local/th); echo \"\$html\" | grep -oE '/_next/static/[^\" ]+' | head -1" \
    >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    phase="$(kubectl -n "$NS" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || echo Missing)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" || "$phase" == "Missing" ]] && break
    sleep 1
  done
  asset="$(kubectl -n "$NS" logs "$name" 2>/dev/null | tr -d '\r' | head -1 || true)"
  kubectl -n "$NS" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if [[ -n "$asset" && "$asset" == /_next/* ]]; then
    t="$(req "$asset")"
    code="$(cat "${t}.code")"
    if [[ "$code" == "200" ]]; then
      ok "static asset ${asset} HTTP 200"
    else
      fail "static asset ${asset} HTTP ${code}"
    fi
    cleanup_tmp "$t"
  else
    fail "could not discover _next static asset from /th HTML"
  fi
fi

# 4) Probe paths are NOT redirected (must be final 200, no 3xx)
for path in /healthz /readyz; do
  tmp="$(mktemp)"
  hdr="$(mktemp)"
  code="$(curl -sS -m 12 -D "$hdr" -o "$tmp" -w '%{http_code}' \
    -H "Host: ${HOST}" --max-redirs 0 "${BASE}${path}" 2>/dev/null || echo 000)"
  loc="$(grep -i '^Location:' "$hdr" 2>/dev/null | head -1 | tr -d '\r' || true)"
  body="$(cat "$tmp" 2>/dev/null || true)"
  rm -f "$tmp" "$hdr"
  if [[ "$code" == "200" ]]; then
    if echo "$body" | grep -qE '"status"\s*:\s*"(ok|ready)"'; then
      ok "probe ${path} HTTP 200 without redirect (json status)"
    else
      ok "probe ${path} HTTP 200 without redirect"
    fi
  elif [[ "$code" =~ ^30[0-9]$ ]]; then
    fail "probe ${path} redirected (${code} ${loc}) — middleware must exclude probes"
  else
    fail "probe ${path} HTTP ${code} (want 200, no redirect)"
  fi
done

# Service-level probe confirmation (bypass ingress)
name="smokepr${RANDOM}"
kubectl -n "$NS" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
kubectl -n "$NS" run "$name" --restart=Never --image=curlimages/curl:8.10.1 \
  --command -- sh -c \
  "c1=\$(curl -sS -m 10 -o /dev/null -w '%{http_code}' http://${APP}.${NS}.svc.cluster.local/healthz); \
   c2=\$(curl -sS -m 10 -o /dev/null -w '%{http_code}' http://${APP}.${NS}.svc.cluster.local/readyz); \
   echo \"\$c1 \$c2\"" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
  phase="$(kubectl -n "$NS" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || echo Missing)"
  [[ "$phase" == "Succeeded" || "$phase" == "Failed" || "$phase" == "Missing" ]] && break
  sleep 1
done
svc_codes="$(kubectl -n "$NS" logs "$name" 2>/dev/null | tr -d '\r' | tail -1 || true)"
kubectl -n "$NS" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
if [[ "$svc_codes" == "200 200" ]]; then
  ok "Service healthz/readyz both 200 (${svc_codes})"
else
  fail "Service healthz/readyz got '${svc_codes}' (want '200 200')"
fi

log ""
log "============================================================"
log "booknbook smoke: PASS=${PASS}  FAIL=${FAIL}"
log "============================================================"
for line in "${REPORT[@]}"; do
  log "$line"
done

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
