#!/usr/bin/env bash
# Install a private TLS + htpasswd Docker Distribution registry on Fedora.
# Run ON Fedora 192.168.152.12 with sudo. Homelab / non-production only.
# Never prints passwords. Never writes credentials into the git repo.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root (sudo)" >&2
  exit 1
fi

REGISTRY_HOST="${REGISTRY_HOST:-registry.homelab.local}"
REGISTRY_IP="${REGISTRY_IP:-192.168.152.12}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
REGISTRY_BIND="${REGISTRY_BIND:-${REGISTRY_IP}:${REGISTRY_PORT}}"
REGISTRY_DATA_DIR="${REGISTRY_DATA_DIR:-/var/lib/solo-empire-registry}"
REGISTRY_CONF_DIR="${REGISTRY_CONF_DIR:-/etc/solo-empire-registry}"
REGISTRY_CERT_DIR="${REGISTRY_CERT_DIR:-${REGISTRY_CONF_DIR}/certs}"
REGISTRY_AUTH_DIR="${REGISTRY_AUTH_DIR:-${REGISTRY_CONF_DIR}/auth}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-public.ecr.aws/docker/library/registry:2.8.3}"
REGISTRY_USER="${REGISTRY_USER:-solo-registry}"
REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-solo-empire-registry}"
STATE_DIR="${REGISTRY_CONF_DIR}/state"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not installed on this host" >&2
  exit 1
fi
if ! systemctl is-active --quiet docker && ! docker info >/dev/null 2>&1; then
  systemctl enable --now docker
fi

command -v openssl >/dev/null
mkdir -p "${REGISTRY_DATA_DIR}" "${REGISTRY_CERT_DIR}" "${REGISTRY_AUTH_DIR}" "${STATE_DIR}"
chmod 700 "${REGISTRY_CONF_DIR}" "${REGISTRY_AUTH_DIR}" "${STATE_DIR}"
chmod 755 "${REGISTRY_DATA_DIR}" "${REGISTRY_CERT_DIR}"

# --- TLS: internal CA + server cert (SAN: hostname + IP) ---
CA_KEY="${REGISTRY_CERT_DIR}/ca.key"
CA_CRT="${REGISTRY_CERT_DIR}/ca.crt"
SRV_KEY="${REGISTRY_CERT_DIR}/server.key"
SRV_CSR="${REGISTRY_CERT_DIR}/server.csr"
SRV_CRT="${REGISTRY_CERT_DIR}/server.crt"
OPENSSL_CFG="${REGISTRY_CERT_DIR}/openssl.cnf"

if [[ ! -f "${CA_CRT}" || ! -f "${SRV_CRT}" ]]; then
  echo "Generating internal CA and server certificate for ${REGISTRY_HOST} / ${REGISTRY_IP}"
  openssl genrsa -out "${CA_KEY}" 4096 2>/dev/null
  openssl req -x509 -new -nodes -key "${CA_KEY}" -sha256 -days 3650 \
    -subj "/CN=Solo Empire Homelab Registry CA/O=Solo Empire Homelab" \
    -out "${CA_CRT}" 2>/dev/null
  openssl genrsa -out "${SRV_KEY}" 2048 2>/dev/null
  cat >"${OPENSSL_CFG}" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = ${REGISTRY_HOST}
O = Solo Empire Homelab
[v3_req]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${REGISTRY_HOST}
IP.1 = ${REGISTRY_IP}
EOF
  openssl req -new -key "${SRV_KEY}" -out "${SRV_CSR}" -config "${OPENSSL_CFG}" 2>/dev/null
  openssl x509 -req -in "${SRV_CSR}" -CA "${CA_CRT}" -CAkey "${CA_KEY}" -CAcreateserial \
    -out "${SRV_CRT}" -days 825 -sha256 -extensions v3_req -extfile "${OPENSSL_CFG}" 2>/dev/null
  chmod 600 "${CA_KEY}" "${SRV_KEY}"
  chmod 644 "${CA_CRT}" "${SRV_CRT}"
else
  echo "Reusing existing certificates under ${REGISTRY_CERT_DIR}"
fi

# --- Auth: htpasswd (password written only under STATE_DIR, mode 0600) ---
HTPASSWD_FILE="${REGISTRY_AUTH_DIR}/htpasswd"
PASS_FILE="${STATE_DIR}/registry.password"
if [[ ! -f "${HTPASSWD_FILE}" || ! -f "${PASS_FILE}" ]]; then
  echo "Generating registry basic-auth credentials for user ${REGISTRY_USER}"
  # 32-byte url-safe password; stored only on this host
  REGISTRY_PASSWORD="$(openssl rand -base64 32 | tr -d '\n' | tr '+/' '-_')"
  umask 077
  printf '%s' "${REGISTRY_PASSWORD}" >"${PASS_FILE}"
  chmod 600 "${PASS_FILE}"
  # Use registry image tooling via docker run httpd htpasswd if local htpasswd missing
  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -Bbn "${REGISTRY_USER}" "${REGISTRY_PASSWORD}" >"${HTPASSWD_FILE}"
  else
    docker run --rm --entrypoint htpasswd \
      public.ecr.aws/docker/library/httpd:2.4.62-alpine \
      -Bbn "${REGISTRY_USER}" "${REGISTRY_PASSWORD}" >"${HTPASSWD_FILE}"
  fi
  chmod 600 "${HTPASSWD_FILE}"
  unset REGISTRY_PASSWORD
else
  echo "Reusing existing htpasswd under ${REGISTRY_AUTH_DIR}"
fi

# --- Registry config.yml ---
CONFIG_YML="${REGISTRY_CONF_DIR}/config.yml"
cat >"${CONFIG_YML}" <<EOF
version: 0.1
log:
  fields:
    service: registry
storage:
  filesystem:
    rootdirectory: /var/lib/registry
  delete:
    enabled: true
http:
  # Listen on all interfaces inside the container; host publish (-p) binds
  # only to the private LAN IP via REGISTRY_BIND.
  addr: 0.0.0.0:5000
  headers:
    X-Content-Type-Options: [nosniff]
  tls:
    certificate: /certs/server.crt
    key: /certs/server.key
auth:
  htpasswd:
    realm: solo-empire-homelab-registry
    path: /auth/htpasswd
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
EOF
chmod 644 "${CONFIG_YML}"

# --- Run container bound to private IP only ---
if docker ps -a --format '{{.Names}}' | grep -qx "${REGISTRY_CONTAINER}"; then
  docker rm -f "${REGISTRY_CONTAINER}" >/dev/null
fi

docker pull "${REGISTRY_IMAGE}" >/dev/null
docker run -d \
  --name "${REGISTRY_CONTAINER}" \
  --restart unless-stopped \
  -p "${REGISTRY_BIND}:5000" \
  -v "${REGISTRY_DATA_DIR}:/var/lib/registry" \
  -v "${REGISTRY_CERT_DIR}:/certs:ro" \
  -v "${REGISTRY_AUTH_DIR}:/auth:ro" \
  -v "${CONFIG_YML}:/etc/docker/registry/config.yml:ro" \
  "${REGISTRY_IMAGE}" >/dev/null

# Wait for TLS port
for i in $(seq 1 30); do
  if curl -fsS --cacert "${CA_CRT}" -u "${REGISTRY_USER}:$(cat "${PASS_FILE}")" \
    "https://${REGISTRY_IP}:${REGISTRY_PORT}/v2/" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Export CA for operators (safe to distribute inside LAN)
install -m 0644 "${CA_CRT}" "${STATE_DIR}/ca.crt"

# Write non-secret summary
cat >"${STATE_DIR}/SUMMARY.txt" <<EOF
Solo Empire Homelab private registry
hostname: ${REGISTRY_HOST}
ip: ${REGISTRY_IP}
port: ${REGISTRY_PORT}
bind: ${REGISTRY_BIND}
image: ${REGISTRY_IMAGE}
data: ${REGISTRY_DATA_DIR}
user: ${REGISTRY_USER}
password_file: ${PASS_FILE}
ca_file: ${STATE_DIR}/ca.crt
tls: internal CA (SAN DNS=${REGISTRY_HOST}, IP=${REGISTRY_IP})
rotation: regenerate certs + htpasswd under ${REGISTRY_CONF_DIR}; restart container
EOF
chmod 644 "${STATE_DIR}/SUMMARY.txt"

echo "Registry installed."
echo "  endpoint: https://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/ (or https://${REGISTRY_IP}:${REGISTRY_PORT}/v2/)"
echo "  user: ${REGISTRY_USER}"
echo "  password file (host-local only): ${PASS_FILE}"
echo "  CA: ${STATE_DIR}/ca.crt"
echo "  summary: ${STATE_DIR}/SUMMARY.txt"
echo "  docker: ${REGISTRY_CONTAINER} on ${REGISTRY_IMAGE}"
