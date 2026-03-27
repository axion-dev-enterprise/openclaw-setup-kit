#!/usr/bin/env bash
set -euo pipefail

CHANNEL_RESOLVER="${CHANNEL_RESOLVER:-/srv/clients/openclaw-admin/tools/ops/resolve_delivery_channel.sh}"
WHATSAPP_SENDER="${WHATSAPP_SENDER:-/srv/clients/openclaw-admin/tools/ops/whatsapp_send_with_retry.sh}"
CONTAINER="${CONTAINER:-root-openclaw-gateway-1}"
ACCOUNT_ID="${ACCOUNT_ID:-axion-11988045139}"

channel=""
target=""
message=""
source="manual_send"
queue_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) channel="${2:-}"; shift 2 ;;
    --target) target="${2:-}"; shift 2 ;;
    --message) message="${2:-}"; shift 2 ;;
    --source) source="${2:-}"; shift 2 ;;
    --queue-file) queue_file="${2:-}"; shift 2 ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$channel" || -z "$target" || -z "$message" ]]; then
  echo "usage: $0 --channel <channel> --target <target> --message <text>" >&2
  exit 2
fi

resolved_channel="$("$CHANNEL_RESOLVER" "$channel")"

if [[ "$resolved_channel" == "whatsapp" ]]; then
  exec "$WHATSAPP_SENDER" --target "$target" --message "$message" --account "$ACCOUNT_ID" --source "$source" --queue-file "$queue_file"
fi

exec docker exec "$CONTAINER" node dist/index.js message send --channel "$resolved_channel" --target "$target" --message "$message" --json
