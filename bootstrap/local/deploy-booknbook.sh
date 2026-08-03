#!/usr/bin/env bash
# Backward-compatible wrapper: second pilot (booknbook).
# Prefer: bash deploy-app.sh booknbook
set -euo pipefail
BOOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$BOOT/deploy-app.sh" booknbook "$@"
