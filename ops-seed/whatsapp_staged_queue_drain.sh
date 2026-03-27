#!/usr/bin/env bash
set -euo pipefail

STATE_ROOT="${STATE_ROOT:-/srv/clients/openclaw-admin/config}"
QUEUE_DIR="${QUEUE_DIR:-$STATE_ROOT/delivery-queue}"
STAGING_DIR="${STAGING_DIR:-$QUEUE_DIR/.staged}"
PROCESSED_DIR="${PROCESSED_DIR:-$QUEUE_DIR/processed}"
SENDER="${SENDER:-/srv/clients/openclaw-admin/tools/ops/safe_message_send.sh}"
HEALTH_FILE="${HEALTH_FILE:-$STATE_ROOT/diagnostics/whatsapp/health.json}"
GOVERNANCE="${GOVERNANCE:-/srv/clients/openclaw-admin/tools/ops/whatsapp_task_governance.sh}"

mkdir -p "$STAGING_DIR" "$PROCESSED_DIR"

if [[ ! -f "$HEALTH_FILE" ]] || ! grep -Eq '"connected": true' "$HEALTH_FILE"; then
  exit 0
fi

python3 - "$STAGING_DIR" <<'PY' >/tmp/openclaw_staged_drain.jsonl
import base64, json, os, sys
root = sys.argv[1]
for name in sorted(os.listdir(root)):
    if not name.endswith('.json'):
        continue
    path = os.path.join(root, name)
    try:
        with open(path, 'r', encoding='utf-8') as fh:
            data = json.load(fh)
    except Exception:
        continue
    channel = data.get('channel', '')
    target = data.get('to', '')
    messages = [p.get('text') for p in (data.get('payloads') or []) if p.get('text')]
    if channel and target and messages:
        print(json.dumps({
            "path": path,
            "channel": channel,
            "target": target,
            "messages": [base64.b64encode(m.encode('utf-8')).decode('ascii') for m in messages]
        }, ensure_ascii=False))
PY

while IFS= read -r row; do
  [[ -z "$row" ]] && continue
  path="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["path"])' "$row")"
  channel="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["channel"])' "$row")"
  target="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["target"])' "$row")"
  "$GOVERNANCE" record --channel "$channel" --target "$target" --message "__queue__$(basename "$path")" --status pending --source staged_drain --queue-file "$path" >/dev/null 2>&1 || true
  ok=1
  python3 -c 'import json,sys; [print(m) for m in json.loads(sys.argv[1])["messages"]]' "$row" >/tmp/openclaw_staged_msgs.txt
  while IFS= read -r encoded; do
    text="$(python3 -c 'import base64,sys; print(base64.b64decode(sys.argv[1]).decode("utf-8"))' "$encoded")"
    if "$GOVERNANCE" can-send --channel "$channel" --target "$target" --message "$text" >/dev/null 2>&1; then
      if ! "$SENDER" --channel "$channel" --target "$target" --message "$text" --source staged_drain --queue-file "$path" >/dev/null 2>&1; then
        ok=0
        break
      fi
    fi
  done </tmp/openclaw_staged_msgs.txt
  rm -f /tmp/openclaw_staged_msgs.txt
  if [[ $ok -eq 1 ]]; then
    python3 - "$row" "$GOVERNANCE" <<'PY'
import base64, json, subprocess, sys
row = json.loads(sys.argv[1])
gov = sys.argv[2]
for encoded in row["messages"]:
    text = base64.b64decode(encoded).decode("utf-8")
    subprocess.run([gov, "record", "--channel", row["channel"], "--target", row["target"], "--message", text, "--status", "completed", "--source", "staged_drain", "--queue-file", row["path"]], check=False)
PY
    "$GOVERNANCE" record --channel "$channel" --target "$target" --message "__queue__$(basename "$path")" --status completed --source staged_drain --queue-file "$path" >/dev/null 2>&1 || true
    mv "$path" "$PROCESSED_DIR/$(basename "$path")" 2>/dev/null || rm -f "$path"
  else
    "$GOVERNANCE" record --channel "$channel" --target "$target" --message "__queue__$(basename "$path")" --status failed --source staged_drain --queue-file "$path" >/dev/null 2>&1 || true
  fi
done </tmp/openclaw_staged_drain.jsonl

rm -f /tmp/openclaw_staged_drain.jsonl
