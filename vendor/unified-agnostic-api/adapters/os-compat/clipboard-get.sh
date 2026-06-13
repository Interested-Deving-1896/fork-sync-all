#!/usr/bin/env bash
# adapters/os-compat/clipboard-get.sh — read clipboard contents
# GET /api/os/clipboard/get
#
# Cross-platform: xclip/xsel (Linux/X11), wl-paste (Wayland), pbpaste (macOS).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

OS_TYPE="$(uname -s)"
content=""
tool=""

case "$OS_TYPE" in
  Darwin)
    if command -v pbpaste &>/dev/null; then
      content="$(pbpaste 2>/dev/null || true)"
      tool="pbpaste"
    fi
    ;;
  Linux)
    if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-paste &>/dev/null; then
      content="$(wl-paste 2>/dev/null || true)"
      tool="wl-paste"
    elif [[ -n "${DISPLAY:-}" ]] && command -v xclip &>/dev/null; then
      content="$(xclip -selection clipboard -o 2>/dev/null || true)"
      tool="xclip"
    elif [[ -n "${DISPLAY:-}" ]] && command -v xsel &>/dev/null; then
      content="$(xsel --clipboard --output 2>/dev/null || true)"
      tool="xsel"
    fi
    ;;
esac

if [[ -z "$tool" ]]; then
  respond_json 200 '{"available":false,"reason":"no clipboard tool found (install xclip, xsel, or wl-paste)"}'
  exit 0
fi

respond_json 200 "{\"available\":true,\"tool\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$tool"),\"content\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$content")}"
