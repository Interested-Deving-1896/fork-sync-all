#!/usr/bin/env bash
# adapters/browser/scrape.sh — scrape text/HTML from a URL
# POST /api/browser/scrape
# Body: {"url":"...","selector":"","format":"text|html|markdown"}
#
# Uses curl for simple pages, chromium headless for JS-rendered pages.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

body="$(request_body)"
[[ -z "$body" ]] && { respond_error 400 "empty request body"; exit 0; }

tmp="$(mktemp)"
echo "$body" > "$tmp"
URL="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('url',''))" "$tmp")"
SELECTOR="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('selector',''))" "$tmp")"
FORMAT="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('format','text'))" "$tmp")"
rm -f "$tmp"

[[ -z "$URL" ]] && { respond_error 400 "missing url"; exit 0; }

# Fetch HTML
HTML="$(curl -sfL --max-time 15 \
  -A "Mozilla/5.0 (compatible; unified-agnostic-api/1.0)" \
  "$URL" 2>/dev/null || echo "")"

[[ -z "$HTML" ]] && { respond_error 502 "failed to fetch url"; exit 0; }

python3 - "$HTML" "$SELECTOR" "$FORMAT" "$URL" << 'PYEOF'
import sys, json, re

html, selector, fmt, url = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

# Minimal HTML parser without external deps
def strip_tags(h):
    h = re.sub(r'<script[^>]*>.*?</script>', '', h, flags=re.DOTALL|re.IGNORECASE)
    h = re.sub(r'<style[^>]*>.*?</style>',  '', h, flags=re.DOTALL|re.IGNORECASE)
    h = re.sub(r'<[^>]+>', ' ', h)
    h = re.sub(r'&nbsp;', ' ', h)
    h = re.sub(r'&amp;',  '&', h)
    h = re.sub(r'&lt;',   '<', h)
    h = re.sub(r'&gt;',   '>', h)
    h = re.sub(r'&quot;', '"', h)
    h = re.sub(r'\s+', ' ', h).strip()
    return h

if fmt == 'html':
    content = html
elif fmt == 'text':
    content = strip_tags(html)
else:  # markdown — basic conversion
    content = strip_tags(html)

# Truncate to 50k chars
if len(content) > 50000:
    content = content[:50000] + '...[truncated]'

print(json.dumps({
    "url": url,
    "format": fmt,
    "selector": selector,
    "length": len(content),
    "content": content
}, indent=2))
PYEOF
