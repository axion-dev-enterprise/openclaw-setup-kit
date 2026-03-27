#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${CONTAINER:-root-openclaw-gateway-1}"
STATE_ROOT="${STATE_ROOT:-/srv/clients/openclaw-admin/config}"
DIAG_DIR="${DIAG_DIR:-$STATE_ROOT/diagnostics/whatsapp}"
HEALTH_FILE="${HEALTH_FILE:-$DIAG_DIR/health.json}"
SUMMARY_FILE="${SUMMARY_FILE:-$DIAG_DIR/delivery-summary.json}"
WINDOW="${WINDOW:-5m}"
repair_now="${1:-}"
NOTIFIER="${NOTIFIER:-/srv/clients/openclaw-admin/tools/ops/whatsapp_problem_notifier.sh}"
RESTART_STAMP="${RESTART_STAMP:-$DIAG_DIR/last-restart.ts}"
SAFE_RESTART="${SAFE_RESTART:-/srv/clients/openclaw-admin/tools/ops/whatsapp_restart_preserve_queue.sh}"

mkdir -p "$DIAG_DIR"
status_json="$(docker exec "$CONTAINER" node dist/index.js channels status --json 2>/dev/null || printf '{}')"
recent_logs="$(docker logs "$CONTAINER" --since "$WINDOW" 2>&1 || true)"

python3 - "$HEALTH_FILE" "$status_json" "$recent_logs" <<'PY'
import json, re, sys, time
health_path, status_raw, logs = sys.argv[1:4]
try:
    status = json.loads(status_raw)
except Exception:
    status = {}
wa = ((status.get("channels") or {}).get("whatsapp") or {})
health = {
    "generatedAt": int(time.time() * 1000),
    "connected": wa.get("connected"),
    "running": wa.get("running"),
    "healthState": wa.get("healthState"),
    "lastDisconnect": wa.get("lastDisconnect"),
    "failures": {
        "connectionClosed": len(re.findall(r"Connection Closed", logs)),
        "status503": len(re.findall(r"status 503", logs)),
        "status408": len(re.findall(r"status 408", logs)),
        "badMac": len(re.findall(r"Bad MAC", logs)),
        "unsupportedChannel": len(re.findall(r"unsupported channel: whatsapp", logs)),
        "unknownTarget": len(re.findall(r'Unknown target "', logs)),
    }
}
with open(health_path, 'w', encoding='utf-8') as fh:
    json.dump(health, fh, ensure_ascii=False, indent=2)
PY

needs_restart=0
recent_duplicate_burst="$(python3 - "$recent_logs" <<'PY'
import re, sys
raw = sys.argv[1]
counts = {}
for hash_id in re.findall(r"Sent message [^ ]+ -> sha256:([0-9a-f]+)", raw):
    counts[hash_id] = counts.get(hash_id, 0) + 1
print(sum(1 for value in counts.values() if value > 2))
PY
)"
if [[ "$repair_now" == "--repair-now" ]]; then
  needs_restart=1
else
  if grep -Eq 'Connection Closed|status 503|status 408|Bad MAC' <<<"$recent_logs"; then
    needs_restart=1
  fi
  if [[ -f "$SUMMARY_FILE" ]]; then
    summary_restart="$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1], encoding="utf-8")); print("1" if any((data.get(k,0) or 0) > 0 for k in ("failed","disconnects","unsupportedChannel","unknownTarget")) else "0")' "$SUMMARY_FILE")"
    if [[ "$summary_restart" == "1" ]]; then
      needs_restart=1
    fi
  fi
  if [[ "$recent_duplicate_burst" -gt 0 ]]; then
    needs_restart=1
  fi
  if ! grep -Eq '"connected": true' "$HEALTH_FILE"; then
    needs_restart=1
  fi
fi

if [[ $needs_restart -eq 1 ]]; then
  now_epoch="$(date +%s)"
  if [[ -f "$RESTART_STAMP" ]]; then
    last_epoch="$(cat "$RESTART_STAMP" 2>/dev/null || printf '0')"
    if [[ $((now_epoch - last_epoch)) -lt 600 ]]; then
      needs_restart=0
    fi
  fi
fi

if [[ $needs_restart -eq 1 ]]; then
  creds_dir="$STATE_ROOT/credentials/whatsapp/axion-11988045139"
  if grep -Eq 'Bad MAC' <<<"$recent_logs"; then
    backup_dir="$DIAG_DIR/session-backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp -a "$creds_dir/." "$backup_dir/" 2>/dev/null || true
    touch "$DIAG_DIR/requires-manual-repair.flag"
  fi
  date +%s >"$RESTART_STAMP"
  if [[ -x "$SAFE_RESTART" ]]; then
    "$SAFE_RESTART" >/dev/null 2>&1 || true
  else
    docker restart "$CONTAINER" >/dev/null
    sleep 12
  fi
fi

if [[ -x "$NOTIFIER" ]]; then
  "$NOTIFIER" >/dev/null 2>&1 || true
fi
