#!/usr/bin/env bash
set -euo pipefail

STATE_ROOT="${STATE_ROOT:-/srv/clients/openclaw-admin/config}"
DIAG_DIR="${DIAG_DIR:-$STATE_ROOT/diagnostics/whatsapp}"
ALIASES_FILE="${ALIASES_FILE:-$DIAG_DIR/target-aliases.json}"
GROUPS_FILE="${GROUPS_FILE:-$DIAG_DIR/groups-cache.json}"

target="${1:-}"
if [[ -z "$target" ]]; then
  echo "usage: $0 <target>" >&2
  exit 2
fi

if [[ "$target" =~ ^\+[1-9][0-9]{7,15}$ ]]; then
  printf '%s\n' "$target"
  exit 0
fi

if [[ "$target" =~ @g\.us$ ]]; then
  printf '%s\n' "$target"
  exit 0
fi

if [[ ! -f "$ALIASES_FILE" ]] || [[ ! -f "$GROUPS_FILE" ]]; then
  echo "target cache missing: $DIAG_DIR" >&2
  exit 3
fi

resolved="$(
python3 - "$target" "$ALIASES_FILE" "$GROUPS_FILE" <<'PY'
import json, sys
needle = sys.argv[1].strip().lower()
aliases_path, groups_path = sys.argv[2], sys.argv[3]

def load(path, key):
    with open(path, 'r', encoding='utf-8') as fh:
        data = json.load(fh)
    return data.get(key, [])

matches = []
for item in load(aliases_path, 'aliases'):
    keys = [str(item.get('alias', '')), str(item.get('target', '')), str(item.get('label', ''))]
    if any(k.lower() == needle for k in keys if k):
        matches.append(item.get('target', ''))
for item in load(groups_path, 'groups'):
    keys = [str(item.get('id', '')), str(item.get('name', '')), str(item.get('alias', ''))]
    if any(k.lower() == needle for k in keys if k):
        matches.append(item.get('id', ''))

unique = []
for entry in matches:
    if entry and entry not in unique:
        unique.append(entry)

if len(unique) == 1:
    print(unique[0])
PY
)"

if [[ -z "$resolved" ]]; then
  echo "unresolved target: $target" >&2
  exit 4
fi

printf '%s\n' "$resolved"
