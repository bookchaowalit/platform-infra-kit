#!/usr/bin/env bash
set -euo pipefail

BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

for command_name in curl sha256sum tar; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

install_kubectl() {
  local version="${KUBECTL_VERSION:-$(curl -fsSL https://dl.k8s.io/release/stable.txt)}"
  local base="https://dl.k8s.io/release/${version}/bin/linux/amd64"
  curl -fsSL -o "$TMP_DIR/kubectl" "$base/kubectl"
  curl -fsSL -o "$TMP_DIR/kubectl.sha256" "$base/kubectl.sha256"
  echo "$(cat "$TMP_DIR/kubectl.sha256")  $TMP_DIR/kubectl" | sha256sum --check -
  install -m 0755 "$TMP_DIR/kubectl" "$BIN_DIR/kubectl"
  echo "Installed kubectl ${version}"
}

install_helm() {
  local tag="${HELM_VERSION:-$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | sed -n 's/.*\"tag_name\": \"\([^\"]*\)\".*/\1/p' | head -n 1)}"
  test -n "$tag" || { echo 'Unable to determine Helm version' >&2; exit 1; }
  local archive="helm-${tag}-linux-amd64.tar.gz"
  curl -fsSL -o "$TMP_DIR/$archive" "https://get.helm.sh/$archive"
  curl -fsSL -o "$TMP_DIR/$archive.sha256sum" "https://get.helm.sh/$archive.sha256sum"
  local expected="$(awk '{print $1}' "$TMP_DIR/$archive.sha256sum")"
  local actual="$(sha256sum "$TMP_DIR/$archive" | awk '{print $1}')"
  test "$expected" = "$actual" || { echo 'Helm checksum mismatch' >&2; exit 1; }
  tar -xzf "$TMP_DIR/$archive" -C "$TMP_DIR"
  install -m 0755 "$TMP_DIR/linux-amd64/helm" "$BIN_DIR/helm"
  echo "Installed Helm ${tag}"
}

install_k3d() {
  local tag="${K3D_VERSION:-$(curl -fsSL https://api.github.com/repos/k3d-io/k3d/releases/latest | sed -n 's/.*\"tag_name\": \"\([^\"]*\)\".*/\1/p' | head -n 1)}"
  test -n "$tag" || { echo 'Unable to determine k3d version' >&2; exit 1; }
  curl -fsSL -o "$TMP_DIR/k3d" "https://github.com/k3d-io/k3d/releases/download/${tag}/k3d-linux-amd64"
  test -s "$TMP_DIR/k3d" || { echo 'k3d download is empty' >&2; exit 1; }
  install -m 0755 "$TMP_DIR/k3d" "$BIN_DIR/k3d"
  echo "Installed k3d ${tag}"
}

install_kubectl
install_helm
install_k3d

echo
echo "Tools installed in $BIN_DIR"
echo "export PATH=\"$BIN_DIR:\$PATH\""
