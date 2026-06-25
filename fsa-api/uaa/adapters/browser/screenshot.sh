#!/usr/bin/env bash
# adapters/browser/screenshot.sh — capture a webpage screenshot
# POST /api/browser/screenshot
# Body: {"url":"...","width":1280,"height":720,"format":"png|jpeg","wait_ms":1000}
#
# Uses puppeteer (Alex313031/puppeteer fork) if available, falls back to
# chromium --headless CLI, then to cutycapt/wkhtmltoimage.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

auth_check

body="$(request_body)"
[[ -z "$body" ]] && { respond_error 400 "empty request body"; exit 0; }

tmp="$(mktemp)"
echo "$body" > "$tmp"

URL="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('url',''))" "$tmp")"
WIDTH="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('width',1280))" "$tmp")"
HEIGHT="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('height',720))" "$tmp")"
FORMAT="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('format','png'))" "$tmp")"
WAIT_MS="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('wait_ms',1000))" "$tmp")"
rm -f "$tmp"

[[ -z "$URL" ]] && { respond_error 400 "missing url"; exit 0; }

OUT_FILE="$(mktemp --suffix=".$FORMAT")"

# Try puppeteer node script first
if command -v node &>/dev/null && [[ -f "$REPO_ROOT/tools/screenshot.js" ]]; then
  node "$REPO_ROOT/tools/screenshot.js" \
    --url "$URL" --width "$WIDTH" --height "$HEIGHT" \
    --format "$FORMAT" --wait "$WAIT_MS" --out "$OUT_FILE" 2>/dev/null
# Fall back to chromium headless CLI
elif command -v chromium-browser &>/dev/null || command -v chromium &>/dev/null || command -v google-chrome &>/dev/null; then
  CHROME="$(command -v chromium-browser || command -v chromium || command -v google-chrome)"
  "$CHROME" \
    --headless --disable-gpu --no-sandbox \
    --window-size="${WIDTH},${HEIGHT}" \
    --screenshot="$OUT_FILE" \
    "$URL" 2>/dev/null || true
else
  rm -f "$OUT_FILE"
  respond_error 503 "no browser available (install chromium or puppeteer)"
  exit 0
fi

if [[ ! -s "$OUT_FILE" ]]; then
  rm -f "$OUT_FILE"
  respond_error 500 "screenshot capture failed"
  exit 0
fi

# Return as base64-encoded JSON
ENCODED="$(base64 < "$OUT_FILE")"
rm -f "$OUT_FILE"
respond_json 200 "{\"url\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$URL"),\"format\":\"$FORMAT\",\"width\":$WIDTH,\"height\":$HEIGHT,\"encoding\":\"base64\",\"data\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$ENCODED")}"
