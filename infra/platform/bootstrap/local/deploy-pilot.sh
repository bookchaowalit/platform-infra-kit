#!/usr/bin/env bash
# Backward-compatible wrapper: first pilot (ai-doc-assistant).
# Prefer: bash deploy-app.sh ai-doc-assistant
set -euo pipefail
BOOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$BOOT/deploy-app.sh" ai-doc-assistant "$@"
