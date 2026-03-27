#!/usr/bin/env bash
set -euo pipefail

STATE_ROOT="${STATE_ROOT:-/srv/clients/openclaw-admin/config}"
DIAG_DIR="${DIAG_DIR:-$STATE_ROOT/diagnostics/whatsapp}"
REGISTRY_DIR="${REGISTRY_DIR:-$DIAG_DIR/task-governance}"
HISTORY_FILE="${HISTORY_FILE:-$DIAG_DIR/task-governance-history.jsonl}"

mkdir -p "$REGISTRY_DIR" "$DIAG_DIR"

usage() {
  cat >&2 <<'EOF'
usage:
  whatsapp_task_governance.sh key --channel <channel> --target <target> --message <text>
  whatsapp_task_governance.sh status --channel <channel> --target <target> --message <text>
  whatsapp_task_governance.sh can-send --channel <channel> --target <target> --message <text> [--ttl-sent 604800] [--ttl-completed 604800]
  whatsapp_task_governance.sh record --channel <channel> --target <target> --message <text> --status <pending|sent|completed|failed|skipped> [--message-id <id>] [--detail <text>] [--source <name>] [--queue-file <path>]
EOF
  exit 2
}

command="${1:-}"
[[ -n "$command" ]] || usage
shift || true

channel=""
target=""
message=""
status=""
message_id=""
detail=""
source=""
queue_file=""
ttl_sent="604800"
ttl_completed="604800"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) channel="${2:-}"; shift 2 ;;
    --target) target="${2:-}"; shift 2 ;;
    --message) message="${2:-}"; shift 2 ;;
    --status) status="${2:-}"; shift 2 ;;
    --message-id) message_id="${2:-}"; shift 2 ;;
    --detail) detail="${2:-}"; shift 2 ;;
    --source) source="${2:-}"; shift 2 ;;
    --queue-file) queue_file="${2:-}"; shift 2 ;;
    --ttl-sent) ttl_sent="${2:-}"; shift 2 ;;
    --ttl-completed) ttl_completed="${2:-}"; shift 2 ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$channel" || -z "$target" || -z "$message" ]]; then
  usage
fi

digest="$(printf '%s' "$channel|$target|$message" | sha256sum | awk '{print $1}')"
state_file="$REGISTRY_DIR/$digest.json"

case "$command" in
  key)
    printf '%s\n' "$digest"
    ;;
  status)
    python3 - "$state_file" "$channel" "$target" "$message" "$digest" <<'PY'
import json, os, sys
path, channel, target, message, digest = sys.argv[1:6]
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as fh:
        print(json.dumps(json.load(fh), ensure_ascii=False))
else:
    print(json.dumps({
        "digest": digest,
        "channel": channel,
        "target": target,
        "status": "unknown",
    }, ensure_ascii=False))
PY
    ;;
  can-send)
    python3 - "$state_file" "$ttl_sent" "$ttl_completed" <<'PY'
import json, os, sys, time
path = sys.argv[1]
ttl_sent = int(sys.argv[2])
ttl_completed = int(sys.argv[3])
now = int(time.time())
if not os.path.exists(path):
    print("allow")
    sys.exit(0)
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
status = data.get("status", "unknown")
updated_at = int(data.get("updatedAt", 0))
age = max(0, now - updated_at) if updated_at else 10**9
if status == "sent" and age < ttl_sent:
    print("block:sent")
    sys.exit(10)
if status == "completed" and age < ttl_completed:
    print("block:completed")
    sys.exit(11)
print("allow")
sys.exit(0)
PY
    ;;
  record)
    [[ -n "$status" ]] || usage
    python3 - "$state_file" "$HISTORY_FILE" "$channel" "$target" "$message" "$digest" "$status" "$message_id" "$detail" "$source" "$queue_file" <<'PY'
import hashlib, json, os, sys, time
state_file, history_file, channel, target, message, digest, status, message_id, detail, source, queue_file = sys.argv[1:12]
now = int(time.time())
message_hash = hashlib.sha256(message.encode("utf-8")).hexdigest()
existing = {}
if os.path.exists(state_file):
    with open(state_file, "r", encoding="utf-8") as fh:
        existing = json.load(fh)
record = {
    "digest": digest,
    "channel": channel,
    "target": target,
    "messageHash": message_hash,
    "status": status,
    "messageId": message_id or existing.get("messageId", ""),
    "detail": detail or existing.get("detail", ""),
    "source": source or existing.get("source", ""),
    "queueFile": queue_file or existing.get("queueFile", ""),
    "createdAt": int(existing.get("createdAt", now)),
    "updatedAt": now,
}
history = list(existing.get("history") or [])
history.append({
    "ts": now,
    "status": status,
    "messageId": message_id or "",
    "detail": detail or "",
    "source": source or "",
    "queueFile": queue_file or "",
})
record["history"] = history[-20:]
os.makedirs(os.path.dirname(state_file), exist_ok=True)
with open(state_file, "w", encoding="utf-8") as fh:
    json.dump(record, fh, ensure_ascii=False, indent=2)
with open(history_file, "a", encoding="utf-8") as fh:
    fh.write(json.dumps({
        "ts": now,
        "digest": digest,
        "channel": channel,
        "target": target,
        "messageHash": message_hash,
        "status": status,
        "messageId": message_id or "",
        "detail": detail or "",
        "source": source or "",
        "queueFile": queue_file or "",
    }, ensure_ascii=False) + "\n")
print(json.dumps(record, ensure_ascii=False))
PY
    ;;
  *)
    usage
    ;;
esac
