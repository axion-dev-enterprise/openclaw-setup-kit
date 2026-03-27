#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${CONTAINER:-root-openclaw-gateway-1}"
STATE_ROOT="${STATE_ROOT:-/srv/clients/openclaw-admin/config}"
DIAG_DIR="${DIAG_DIR:-$STATE_ROOT/diagnostics/whatsapp}"
SENDER="${SENDER:-/srv/clients/openclaw-admin/tools/ops/whatsapp_send_with_retry.sh}"

mkdir -p "$DIAG_DIR"
logs="$(docker logs "$CONTAINER" --since 15m 2>&1 || true)"
target="$(printf '%s' "$logs" | sed -n 's/.*Inbound message \(+[0-9]\+\) -> .* (direct,.*/\1/p' | tail -n 1)"
failed_direct="$(printf '%s' "$logs" | grep -E 'Failed sending web auto-reply to \+[0-9]+' | tail -n 1 || true)"

if [[ -n "$target" ]] && [[ -n "$failed_direct" ]]; then
  "$SENDER" --target "$target" --message "Recebi sua mensagem e estou verificando. Retorno em breve." >/dev/null 2>&1 || true
fi
