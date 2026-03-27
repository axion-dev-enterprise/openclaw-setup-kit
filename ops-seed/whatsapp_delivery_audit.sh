#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${CONTAINER:-root-openclaw-gateway-1}"
STATE_ROOT="${STATE_ROOT:-/srv/clients/openclaw-admin/config}"
DIAG_DIR="${DIAG_DIR:-$STATE_ROOT/diagnostics/whatsapp}"
EVENTS_FILE="${EVENTS_FILE:-$DIAG_DIR/delivery-events.jsonl}"
SUMMARY_FILE="${SUMMARY_FILE:-$DIAG_DIR/delivery-summary.json}"
WINDOW="${WINDOW:-20m}"

mkdir -p "$DIAG_DIR"
logs="$(docker logs "$CONTAINER" --since "$WINDOW" 2>&1 || true)"

python3 - "$EVENTS_FILE" "$SUMMARY_FILE" "$logs" <<'PY'
import json, re, sys, time
events_path, summary_path, raw = sys.argv[1:4]

patterns = [
    ("inbound", re.compile(r"Inbound message ([^ ]+) -> ([^ ]+) \((group|direct), ([0-9]+) chars\)")),
    ("auto_reply", re.compile(r"Auto-replied to ([^ ]+)")),
    ("send_ok", re.compile(r"Sent message ([^ ]+) -> sha256:([0-9a-f]+)")),
    ("send_fail", re.compile(r"Failed sending web auto-reply to ([^:]+): (.+)")),
    ("disconnect", re.compile(r"Web connection closed \(status ([0-9]+)\)\. (.+)")),
    ("unsupported_channel", re.compile(r"unsupported channel: ([A-Za-z0-9_-]+)")),
    ("unknown_target", re.compile(r'Unknown target "([^"]+)" for WhatsApp')),
]

rows = []
summary = {
    "generatedAt": int(time.time() * 1000),
    "window": raw.count("\n"),
    "inbound": 0,
    "autoReply": 0,
    "delivered": 0,
    "failed": 0,
    "disconnects": 0,
    "unsupportedChannel": 0,
    "unknownTarget": 0,
    "duplicateBursts": 0
}
hash_counts = {}

for line in raw.splitlines():
    for kind, regex in patterns:
        match = regex.search(line)
        if not match:
            continue
        if kind == "inbound":
            summary["inbound"] += 1
            rows.append({"ts": int(time.time() * 1000), "event": "inbound", "from": match.group(1), "to": match.group(2), "scope": match.group(3), "chars": int(match.group(4))})
        elif kind == "auto_reply":
            summary["autoReply"] += 1
            rows.append({"ts": int(time.time() * 1000), "event": "auto_reply", "target": match.group(1)})
        elif kind == "send_ok":
            summary["delivered"] += 1
            hash_counts[match.group(2)] = hash_counts.get(match.group(2), 0) + 1
            rows.append({"ts": int(time.time() * 1000), "event": "delivered", "messageId": match.group(1), "hash": match.group(2)})
        elif kind == "send_fail":
            summary["failed"] += 1
            rows.append({"ts": int(time.time() * 1000), "event": "delivery_failed", "target": match.group(1), "detail": match.group(2)})
        elif kind == "disconnect":
            summary["disconnects"] += 1
            rows.append({"ts": int(time.time() * 1000), "event": "disconnect", "status": int(match.group(1)), "detail": match.group(2)})
        elif kind == "unsupported_channel":
            summary["unsupportedChannel"] += 1
            rows.append({"ts": int(time.time() * 1000), "event": "unsupported_channel", "channel": match.group(1)})
        elif kind == "unknown_target":
            summary["unknownTarget"] += 1
            rows.append({"ts": int(time.time() * 1000), "event": "unknown_target", "target": match.group(1)})
        break

with open(events_path, 'a', encoding='utf-8') as fh:
    for row in rows:
        fh.write(json.dumps(row, ensure_ascii=False) + "\n")

summary["duplicateBursts"] = sum(1 for count in hash_counts.values() if count > 2)
summary["healthy"] = summary["disconnects"] == 0 and summary["failed"] == 0 and summary["unsupportedChannel"] == 0 and summary["unknownTarget"] == 0 and summary["duplicateBursts"] == 0
with open(summary_path, 'w', encoding='utf-8') as fh:
    json.dump(summary, fh, ensure_ascii=False, indent=2)
PY
