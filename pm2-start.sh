#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

LIQ_BIN="${LIQ_BIN:-/usr/bin/liquidsoap}"
SCRIPT="${SCRIPT:-$ROOT/script.liq}"
USER_ID="${LIQ_USER_ID:-user1}"
API_TOKEN="${LIQ_API_TOKEN:-}"
CONTROL_PORT="${LIQ_CONTROL_PORT:-7001}"

exec "$LIQ_BIN" "$SCRIPT" -- "$USER_ID" "$API_TOKEN" "$CONTROL_PORT"