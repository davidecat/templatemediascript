#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

LIQ_BIN="${LIQ_BIN:-/usr/bin/liquidsoap}"
SCRIPT="${SCRIPT:-$ROOT/script.liq}"
USER_ID="${LIQ_USER_ID:-user1}"

# PM2 supervises the process — liquidsoap must stay in foreground (false).
exec "$LIQ_BIN" "$SCRIPT" -- "$USER_ID" "false"
