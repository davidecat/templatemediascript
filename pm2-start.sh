#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

LIQ_BIN="${LIQ_BIN:-/usr/bin/liquidsoap}"
SCRIPT="${SCRIPT:-$ROOT/script.liq}"
USER_ID="${LIQ_USER_ID:-user1}"
# script.liq argv(2) must be "true" or "false" (daemonize). PM2 needs foreground.
DAEMONIZE="${LIQ_DAEMONIZE:-false}"

exec "$LIQ_BIN" "$SCRIPT" -- "$USER_ID" "$DAEMONIZE"
