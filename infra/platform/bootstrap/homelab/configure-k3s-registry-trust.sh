#!/usr/bin/env bash
# Configure Homelab K3s node to trust the Fedora private registry.
# Run from the operator workstation. Does not print passwords.
set -euo pipefail

FEDORA_HOST="${FEDORA_HOST:-192.168.152.12}"
FEDORA_USER="${FEDORA_USER:-bookchaowalit}"
K3S_HOST="${K3S_HOST:-192.168.152.114}"
K3S_USER="${K3S_USER:-soloadmin}"
REGISTRY_HOST="${REGISTRY_HOST:-registry.homelab.local}"
REGISTRY_IP="${REGISTRY_IP:-192.168.152.12}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
REGISTRY_USER="${REGISTRY_USER:-solo-registry}"
SSH_FEDORA=(ssh -o BatchMode=yes -o ConnectTimeout=10 "${FEDORA_USER}@${FEDORA_HOST}")
SSH_K3S=(ssh -o BatchMode=yes -o ConnectTimeout=10 "${K3S_USER}@${K3S_HOST}")
SCP=(scp -o BatchMode=yes -o ConnectTimeout=10)

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "Fetching CA and credentials from Fedora (no password echo)..."
"${SCP}" "${FEDORA_USER}@${FEDORA_HOST}:/etc/solo-empire-registry/state/ca.crt" "${TMP}/ca.crt"
# password file is root-only; try sudo cat via ssh
"${SSH_FEDORA[@]}" "sudo cat /etc/solo-empire-registry/state/registry.password" >"${TMP}/registry.password"
chmod 600 "${TMP}/registry.password"
PASS="$(tr -d '\n' <"${TMP}/registry.password")"

# Build registries.yaml on the fly without echoing password
export REGISTRY_HOST REGISTRY_IP REGISTRY_PORT REGISTRY_USER PASS
python3 - <<'PY' >"${TMP}/registries.yaml"
import os
host = os.environ["REGISTRY_HOST"]
ip = os.environ["REGISTRY_IP"]
port = os.environ["REGISTRY_PORT"]
user = os.environ["REGISTRY_USER"]
password = os.environ["PASS"]
# YAML-safe single quotes for password
def sq(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"
print(f"""mirrors:
  "{host}:{port}":
    endpoint:
      - "https://{ip}:{port}"
  "{ip}:{port}":
    endpoint:
      - "https://{ip}:{port}"
configs:
  "{host}:{port}":
    auth:
      username: {sq(user)}
      password: {sq(password)}
    tls:
      ca_file: /etc/rancher/k3s/registry-ca.crt
  "{ip}:{port}":
    auth:
      username: {sq(user)}
      password: {sq(password)}
    tls:
      ca_file: /etc/rancher/k3s/registry-ca.crt
""")
PY
unset PASS
chmod 600 "${TMP}/registries.yaml"

echo "Installing CA + registries.yaml on K3s node..."
"${SCP}" "${TMP}/ca.crt" "${K3S_USER}@${K3S_HOST}:/tmp/solo-registry-ca.crt"
"${SCP}" "${TMP}/registries.yaml" "${K3S_USER}@${K3S_HOST}:/tmp/solo-registries.yaml"
"${SSH_K3S[@]}" "sudo mkdir -p /etc/rancher/k3s /usr/local/share/ca-certificates
sudo install -m 0644 /tmp/solo-registry-ca.crt /etc/rancher/k3s/registry-ca.crt
sudo install -m 0644 /tmp/solo-registry-ca.crt /usr/local/share/ca-certificates/solo-registry-ca.crt
if command -v update-ca-certificates >/dev/null; then sudo update-ca-certificates >/dev/null 2>&1 || true; fi
sudo install -m 0600 /tmp/solo-registries.yaml /etc/rancher/k3s/registries.yaml
# hosts entry for registry hostname
if ! grep -q '${REGISTRY_HOST}' /etc/hosts; then
  echo '${REGISTRY_IP} ${REGISTRY_HOST}' | sudo tee -a /etc/hosts >/dev/null
else
  sudo sed -i 's/.*${REGISTRY_HOST}.*/${REGISTRY_IP} ${REGISTRY_HOST}/' /etc/hosts
fi
rm -f /tmp/solo-registry-ca.crt /tmp/solo-registries.yaml
sudo systemctl restart k3s
"

echo "Waiting for K3s node Ready..."
for i in $(seq 1 36); do
  if "${SSH_K3S[@]}" "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl get nodes --no-headers 2>/dev/null | grep -q ' Ready '"; then
    echo "K3s Ready after registry trust reload"
    break
  fi
  sleep 5
done

# Also install CA + docker login on operator workstation for push (optional)
if command -v docker >/dev/null 2>&1; then
  mkdir -p "${HOME}/.config/solo-empire-homelab"
  install -m 0644 "${TMP}/ca.crt" "${HOME}/.config/solo-empire-homelab/registry-ca.crt"
  # system trust may need sudo; for docker, use certs.d
  DOCKER_CERT_DIR="/etc/docker/certs.d/${REGISTRY_HOST}:${REGISTRY_PORT}"
  DOCKER_CERT_DIR_IP="/etc/docker/certs.d/${REGISTRY_IP}:${REGISTRY_PORT}"
  if [[ -w /etc/docker/certs.d ]] || sudo -n true 2>/dev/null; then
    sudo mkdir -p "${DOCKER_CERT_DIR}" "${DOCKER_CERT_DIR_IP}"
    sudo install -m 0644 "${TMP}/ca.crt" "${DOCKER_CERT_DIR}/ca.crt"
    sudo install -m 0644 "${TMP}/ca.crt" "${DOCKER_CERT_DIR_IP}/ca.crt"
  fi
  # docker login without printing password
  REGISTRY_PASSWORD="$(tr -d '\n' <"${TMP}/registry.password")"
  echo "${REGISTRY_PASSWORD}" | docker login "${REGISTRY_HOST}:${REGISTRY_PORT}" -u "${REGISTRY_USER}" --password-stdin >/dev/null
  echo "${REGISTRY_PASSWORD}" | docker login "${REGISTRY_IP}:${REGISTRY_PORT}" -u "${REGISTRY_USER}" --password-stdin >/dev/null
  unset REGISTRY_PASSWORD
  # hosts
  if ! grep -q "${REGISTRY_HOST}" /etc/hosts 2>/dev/null; then
    echo "${REGISTRY_IP} ${REGISTRY_HOST}" | sudo tee -a /etc/hosts >/dev/null || true
  fi
  echo "Operator docker login configured for ${REGISTRY_HOST}:${REGISTRY_PORT}"
fi

echo "configure-k3s-registry-trust: done"
