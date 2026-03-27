#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${CONTAINER:-root-openclaw-gateway-1}"
ACCOUNT_ID="${ACCOUNT_ID:-axion-11988045139}"
STATE_ROOT="${STATE_ROOT:-/srv/clients/openclaw-admin/config}"
DIAG_DIR="${DIAG_DIR:-$STATE_ROOT/diagnostics/whatsapp}"
EVENTS_FILE="${EVENTS_FILE:-$DIAG_DIR/delivery-events.jsonl}"
LOCK_DIR="${LOCK_DIR:-$DIAG_DIR/send-locks}"
RESULT_DIR="${RESULT_DIR:-$DIAG_DIR/send-results}"
ISSUE_DIR="${ISSUE_DIR:-$DIAG_DIR/problem-queue}"
RESOLVER="${RESOLVER:-/srv/clients/openclaw-admin/tools/ops/whatsapp_target_resolver.sh}"
WATCHDOG="${WATCHDOG:-/srv/clients/openclaw-admin/tools/ops/whatsapp_delivery_guard.sh}"
GOVERNANCE="${GOVERNANCE:-/srv/clients/openclaw-admin/tools/ops/whatsapp_task_governance.sh}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-4}"

mkdir -p "$DIAG_DIR" "$LOCK_DIR" "$RESULT_DIR" "$ISSUE_DIR"

target=""
message=""
source="direct_send"
queue_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) target="${2:-}"; shift 2 ;;
    --message) message="${2:-}"; shift 2 ;;
    --account) ACCOUNT_ID="${2:-}"; shift 2 ;;
    --attempts) MAX_ATTEMPTS="${2:-}"; shift 2 ;;
    --source) source="${2:-}"; shift 2 ;;
    --queue-file) queue_file="${2:-}"; shift 2 ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$target" ]] || [[ -z "$message" ]]; then
  echo "usage: $0 --target <jid|e164|alias> --message <text>" >&2
  exit 2
fi

resolved_target="$("$RESOLVER" "$target")"
digest="$(printf '%s' "$resolved_target|$message" | sha256sum | awk '{print $1}')"
lock_file="$LOCK_DIR/$digest.lock"
result_file="$RESULT_DIR/$digest.json"

read_cached_result() {
  python3 - "$result_file" <<'PY'
import json, os, sys, time
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(1)
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
ts = int(data.get("ts", 0))
raw = data.get("raw", "")
message_id = data.get("messageId", "")
if message_id and ts and (time.time() - ts) < 180:
    print(raw)
    sys.exit(0)
sys.exit(1)
PY
}

exec 9>"$lock_file"
flock -w 30 9
governance_state="$("$GOVERNANCE" status --channel whatsapp --target "$resolved_target" --message "$message")"
governance_status="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("status","unknown"))' "$governance_state")"
governance_message_id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("messageId",""))' "$governance_state")"
if ! "$GOVERNANCE" can-send --channel whatsapp --target "$resolved_target" --message "$message" >/tmp/whatsapp_governance_gate.$$ 2>/dev/null; then
  if [[ -n "$governance_message_id" ]] && [[ "$governance_status" =~ ^(sent|completed)$ ]]; then
    if read_cached_result >/tmp/whatsapp_send_cached_result.$$ 2>/dev/null; then
      cat /tmp/whatsapp_send_cached_result.$$
      rm -f /tmp/whatsapp_send_cached_result.$$ /tmp/whatsapp_governance_gate.$$ 2>/dev/null || true
      exit 0
    fi
    python3 - "$governance_status" "$governance_message_id" <<'PY'
import json, sys
status, message_id = sys.argv[1:3]
print(json.dumps({"status": "deduped", "governanceStatus": status, "messageId": message_id}, ensure_ascii=False))
PY
    rm -f /tmp/whatsapp_send_cached_result.$$ /tmp/whatsapp_governance_gate.$$ 2>/dev/null || true
    exit 0
  fi
fi
rm -f /tmp/whatsapp_governance_gate.$$ 2>/dev/null || true
if read_cached_result >/tmp/whatsapp_send_cached_result.$$ 2>/dev/null; then
  "$GOVERNANCE" record --channel whatsapp --target "$resolved_target" --message "$message" --status sent --source "$source" --queue-file "$queue_file" >/dev/null 2>&1 || true
  cat /tmp/whatsapp_send_cached_result.$$
  rm -f /tmp/whatsapp_send_cached_result.$$
  exit 0
fi
rm -f /tmp/whatsapp_send_cached_result.$$ 2>/dev/null || true

"$GOVERNANCE" record --channel whatsapp --target "$resolved_target" --message "$message" --status pending --source "$source" --queue-file "$queue_file" >/dev/null 2>&1 || true

log_event() {
  python3 - "$EVENTS_FILE" "$1" "$resolved_target" "$2" "$3" <<'PY'
import json, sys, time
path, event, target, status, detail = sys.argv[1:6]
with open(path, 'a', encoding='utf-8') as fh:
    fh.write(json.dumps({
        "ts": int(time.time() * 1000),
        "event": event,
        "target": target,
        "status": status,
        "detail": detail
    }, ensure_ascii=False) + "\n")
PY
}

queue_problem_notice() {
  python3 - "$ISSUE_DIR" "$resolved_target" "$1" <<'PY'
import json, os, sys, time, hashlib
issue_dir, target, detail = sys.argv[1:4]
digest = hashlib.sha256(f"{target}|{detail}".encode("utf-8")).hexdigest()
path = os.path.join(issue_dir, f"{digest}.json")
payload = {
    "ts": int(time.time()),
    "target": target,
    "detail": detail,
    "notice": "Estou com instabilidade operacional, mas recebi sua mensagem e vou continuar o atendimento sem perder o contexto."
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
PY
}

attempt=1
backoffs=(2 5 10 20)
while [[ $attempt -le $MAX_ATTEMPTS ]]; do
  log_event send_attempt attempt "attempt=$attempt"
  raw="$(
    docker exec "$CONTAINER" node dist/index.js message send --channel whatsapp --account "$ACCOUNT_ID" --target "$resolved_target" --message "$message" --json 2>&1
  )"
  message_id="$(python3 - "$raw" <<'PY'
import json, sys
data = sys.argv[1]
try:
    obj = json.loads(data)
    message_id = (
        obj.get('messageId', '')
        or obj.get('id', '')
        or obj.get('payload', {}).get('result', {}).get('messageId', '')
        or obj.get('payload', {}).get('result', {}).get('id', '')
    )
    print(message_id)
except Exception:
    print('')
PY
)"
  if [[ -n "$message_id" ]]; then
    python3 - "$result_file" "$message_id" "$raw" <<'PY'
import json, sys, time
path, message_id, raw = sys.argv[1:4]
with open(path, "w", encoding="utf-8") as fh:
    json.dump({
        "ts": int(time.time()),
        "messageId": message_id,
        "raw": raw
    }, fh, ensure_ascii=False)
PY
    "$GOVERNANCE" record --channel whatsapp --target "$resolved_target" --message "$message" --status sent --message-id "$message_id" --detail "delivered" --source "$source" --queue-file "$queue_file" >/dev/null 2>&1 || true
    log_event send_result delivered "$message_id"
    printf '%s\n' "$raw"
    exit 0
  fi

  if grep -Eq 'Connection Closed|Stream Errored|status 503|status 408|timed out|Bad MAC|Message failed|web auto-reply' <<<"$raw"; then
    log_event send_result transient_failure "$(printf '%s' "$raw" | tail -c 300)"
    if [[ $attempt -ge 2 ]]; then
      "$WATCHDOG" --repair-now >/dev/null 2>&1 || true
    fi
    sleep "${backoffs[$((attempt-1))]:-20}"
  else
    "$GOVERNANCE" record --channel whatsapp --target "$resolved_target" --message "$message" --status failed --detail "$(printf '%s' "$raw" | tail -c 300)" --source "$source" --queue-file "$queue_file" >/dev/null 2>&1 || true
    log_event send_result hard_failure "$(printf '%s' "$raw" | tail -c 300)"
    queue_problem_notice "$(printf '%s' "$raw" | tail -c 300)"
    printf '%s\n' "$raw" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
done

"$GOVERNANCE" record --channel whatsapp --target "$resolved_target" --message "$message" --status failed --detail "delivery failed after $MAX_ATTEMPTS attempts" --source "$source" --queue-file "$queue_file" >/dev/null 2>&1 || true
log_event send_result exhausted "max_attempts=$MAX_ATTEMPTS"
queue_problem_notice "delivery failed after $MAX_ATTEMPTS attempts"
printf 'delivery failed after %s attempts\n' "$MAX_ATTEMPTS" >&2
exit 1
