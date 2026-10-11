#!/usr/bin/env bash
set -euo pipefail

BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
export PATH="$BIN_DIR:$PATH"
failures=0

check_command() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    printf 'OK   %-12s %s\n' "$name" "$(command -v "$name")"
  else
    printf 'MISS %-12s\n' "$name"
    failures=$((failures + 1))
  fi
}

check_command docker
check_command kubectl
check_command helm
check_command k3d

if ! docker info >/dev/null 2>&1; then
  echo 'FAIL Docker daemon is not reachable'
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  echo "Preflight failed: $failures check(s) missing"
  exit 1
fi

echo 'Preflight OK'
