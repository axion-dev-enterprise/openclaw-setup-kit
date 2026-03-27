#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${CONTAINER:-root-openclaw-gateway-1}"
STATE_ROOT="${STATE_ROOT:-/srv/clients/openclaw-admin/config}"
DIAG_DIR="${DIAG_DIR:-$STATE_ROOT/diagnostics/whatsapp}"
GROUPS_FILE="${GROUPS_FILE:-$DIAG_DIR/groups-cache.json}"
ALIASES_FILE="${ALIASES_FILE:-$DIAG_DIR/target-aliases.json}"

mkdir -p "$DIAG_DIR"

groups_json="$(docker exec "$CONTAINER" node dist/index.js directory groups list --channel whatsapp --json 2>/dev/null || printf '[]')"
recent_jids="$( (docker logs "$CONTAINER" --since 7d 2>&1 || true) | sed -n 's/.*Inbound message \([0-9]\+@g\.us\).*/\1/p' | sort -u )"
session_jids="$(
python3 - "$STATE_ROOT" <<'PY'
import glob, json, os, re, sys
root = sys.argv[1]
seen = set()
pattern = re.compile(r"agent:[^:]+:whatsapp:group:([0-9]+@g\.us)")
for path in glob.glob(os.path.join(root, "agents", "*", "sessions", "sessions.json")):
    try:
        data = json.load(open(path, 'r', encoding='utf-8'))
    except Exception:
        continue
    if isinstance(data, dict):
        entries = []
        for key, value in data.items():
            if isinstance(value, dict):
                item = dict(value)
                item.setdefault("key", key)
                entries.append(item)
        entries.extend(data.get("sessions") or [])
        entries.extend(data.get("items") or [])
    else:
        entries = data
    for item in entries or []:
        if not isinstance(item, dict):
            continue
        key = str(item.get("key", ""))
        match = pattern.search(key)
        if match:
            seen.add(match.group(1))
for jid in sorted(seen):
    print(jid)
PY
)"

python3 - "$GROUPS_FILE" "$ALIASES_FILE" "$groups_json" "$recent_jids" "$session_jids" <<'PY'
import json, sys, time
groups_path, aliases_path, groups_json, recent_jids_blob, session_jids_blob = sys.argv[1:6]
recent_jids = [line.strip() for line in recent_jids_blob.splitlines() if line.strip()]
session_jids = [line.strip() for line in session_jids_blob.splitlines() if line.strip()]
try:
    listed = json.loads(groups_json)
except Exception:
    listed = []

groups = []
seen = set()
for item in listed:
    gid = item.get("id") or item.get("groupId") or item.get("jid")
    if not gid:
        continue
    record = {
        "id": gid,
        "name": item.get("name"),
        "alias": item.get("name"),
        "source": "directory"
    }
    if gid not in seen:
        groups.append(record)
        seen.add(gid)
for gid in recent_jids:
    if gid not in seen:
        groups.append({
            "id": gid,
            "name": None,
            "alias": None,
            "source": "logs"
        })
        seen.add(gid)
for gid in session_jids:
    if gid not in seen:
        groups.append({
            "id": gid,
            "name": None,
            "alias": None,
            "source": "sessions"
        })
        seen.add(gid)

with open(groups_path, 'w', encoding='utf-8') as fh:
    json.dump({"generatedAt": int(time.time() * 1000), "groups": groups}, fh, ensure_ascii=False, indent=2)

try:
    with open(aliases_path, 'r', encoding='utf-8') as fh:
        aliases = json.load(fh)
except Exception:
    aliases = {"generatedAt": None, "aliases": []}
if "aliases" not in aliases:
    aliases = {"generatedAt": None, "aliases": []}
aliases["generatedAt"] = int(time.time() * 1000)
with open(aliases_path, 'w', encoding='utf-8') as fh:
    json.dump(aliases, fh, ensure_ascii=False, indent=2)
PY
