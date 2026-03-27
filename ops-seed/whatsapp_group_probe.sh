#!/usr/bin/env bash
set -euo pipefail

SENDER="${SENDER:-/srv/clients/openclaw-admin/tools/ops/whatsapp_send_with_retry.sh}"
target="${1:-}"
message="${2:-TESTE_DIAGNOSTICO_OPENCLAW}"

if [[ -z "$target" ]]; then
  echo "usage: $0 <target-or-alias> [message]" >&2
  exit 2
fi

"$SENDER" --target "$target" --message "$message"
