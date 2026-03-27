#!/usr/bin/env bash
set -euo pipefail

STATE_ROOT="${STATE_ROOT:-/srv/clients/openclaw-admin/config}"
DIAG_DIR="${DIAG_DIR:-$STATE_ROOT/diagnostics/whatsapp}"
ISSUE_DIR="${ISSUE_DIR:-$DIAG_DIR/problem-queue}"
HEALTH_FILE="${HEALTH_FILE:-$DIAG_DIR/health.json}"
SENDER="${SENDER:-/srv/clients/openclaw-admin/tools/ops/whatsapp_send_with_retry.sh}"

mkdir -p "$ISSUE_DIR"

if [[ ! -f "$HEALTH_FILE" ]] || ! grep -Eq '"connected": true' "$HEALTH_FILE"; then
  exit 0
fi

python3 - "$ISSUE_DIR" <<'PY' >/tmp/whatsapp_problem_notifier_list.txt
import json, os, sys
root = sys.argv[1]
items = []
for name in sorted(os.listdir(root)):
    if not name.endswith('.json'):
        continue
    path = os.path.join(root, name)
    try:
        with open(path, 'r', encoding='utf-8') as fh:
            data = json.load(fh)
    except Exception:
        continue
    items.append((path, data.get('target', ''), data.get('notice', '')))
for path, target, notice in items[:10]:
    if target and notice:
        print(path)
        print(target)
        print(notice)
PY

while IFS= read -r path && IFS= read -r target && IFS= read -r notice; do
  if "$SENDER" --target "$target" --message "$notice" >/dev/null 2>&1; then
    rm -f "$path"
  fi
done </tmp/whatsapp_problem_notifier_list.txt

rm -f /tmp/whatsapp_problem_notifier_list.txt
