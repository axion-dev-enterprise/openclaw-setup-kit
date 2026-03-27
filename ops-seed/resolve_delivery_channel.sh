#!/usr/bin/env bash
set -euo pipefail

raw="${1:-}"
if [[ -z "$raw" ]]; then
  echo "usage: $0 <channel>" >&2
  exit 2
fi

normalized="$(python3 - "$raw" <<'PY'
import re, sys
text = sys.argv[1].strip().lower()
text = re.sub(r'^\[([^\]]+)\]\([^)]+\)$', r'\1', text)
text = re.sub(r'[`*_#>]+', '', text).strip()
text = text.replace(' ', '').replace('-', '')
aliases = {
    'wa': 'whatsapp',
    'whats': 'whatsapp',
    'whatsapp': 'whatsapp',
    'discord': 'discord',
    'disc': 'discord',
    'telegram': 'telegram',
    'tg': 'telegram',
    'slack': 'slack',
    'signal': 'signal',
    'imessage': 'imessage',
    'googlechat': 'googlechat',
    'irc': 'irc',
    'line': 'line',
}
print(aliases.get(text, ''))
PY
)"

if [[ -z "$normalized" ]]; then
  echo "unsupported channel ref: $raw" >&2
  exit 4
fi

printf '%s\n' "$normalized"
