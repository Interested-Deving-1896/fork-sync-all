#!/usr/bin/env bash
# adapters/os-compat/clipboard-set.sh — write to clipboard
# POST /api/os/clipboard/set
# Body: {"text":"..."}
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

auth_check

body="$(request_body)"
tmp="$(mktemp)"
echo "$body" > "$tmp"
text="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('text',''))" "$tmp")"
rm -f "$tmp"

OS_TYPE="$(uname -s)"
tool=""

case "$OS_TYPE" in
  Darwin)
    if command -v pbcopy &>/dev/null; then
      printf '%s' "$text" | pbcopy && tool="pbcopy"
    fi
    ;;
  Linux)
    if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy &>/dev/null; then
      printf '%s' "$text" | wl-copy && tool="wl-copy"
    elif [[ -n "${DISPLAY:-}" ]] && command -v xclip &>/dev/null; then
      printf '%s' "$text" | xclip -selection clipboard && tool="xclip"
    elif [[ -n "${DISPLAY:-}" ]] && command -v xsel &>/dev/null; then
      printf '%s' "$text" | xsel --clipboard --input && tool="xsel"
    fi
    ;;
esac

if [[ -z "$tool" ]]; then
  respond_error 503 "no clipboard tool available"
  exit 0
fi

respond_json 200 "{\"status\":\"ok\",\"tool\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$tool"),\"length\":${#text}}"
