#!/usr/bin/env bash
# scripts/notifications.sh — GitHub notifications manager
#
# Fetches, filters, triages, and acts on GitHub notifications for the
# Interested-Deving-1896 org. Supports CLI, TUI (fzf), and JSON output modes.
#
# Usage:
#   notifications.sh [OPTIONS]
#
# Options:
#   --list              List unread notifications (default)
#   --tui               Interactive TUI via fzf
#   --json              Output raw JSON
#   --mark-read [ID]    Mark notification(s) read (blank = all)
#   --snooze ID HOURS   Snooze a notification for N hours
#   --open ID           Open notification subject in browser
#   --filter TYPE       Filter by type: ci_activity|mention|review_requested|all
#   --filter-repo REPO  Filter by repo name substring
#   --auto-triage       Auto-mark known-safe patterns as read
#   --scope SCOPE       all|participating|unread (default: unread)
#   --limit N           Max notifications to fetch (default: 50)
#   --serve             Start the web UI server (port 7788)
#   --help              Show this help
#
# Environment:
#   GH_TOKEN   — GitHub PAT (falls back to SYNC_TOKEN)
#   BROWSER    — browser command for --open (default: xdg-open)
#
# Known-safe auto-triage patterns (--auto-triage):
#   - "Mirror to OpenOS-Project-OSP" failures in consumer repos
#   - "Sync btrfs-devel Branches" failures (pre-existing, handled upstream)
#   - Quota-exhaustion artifacts (workflow failed, reason: rate limit)
#   - Dependabot auto-merged PRs
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Token ─────────────────────────────────────────────────────────────────────
GH_TOKEN="${GH_TOKEN:-${SYNC_TOKEN:-}}"
: "${GH_TOKEN:?Set GH_TOKEN or SYNC_TOKEN}"
export GH_TOKEN

# ── Defaults ──────────────────────────────────────────────────────────────────
MODE="list"
FILTER_TYPE="all"
FILTER_REPO=""
SCOPE="unread"
LIMIT=50
MARK_READ_ID=""
SNOOZE_ID=""
SNOOZE_HOURS=""
OPEN_ID=""
AUTO_TRIAGE=false
JSON_MODE=false
SERVE=false
WEB_PORT=7788

# ── Logging (all to stderr) ───────────────────────────────────────────────────
info()  { echo "[notifications] $*" >&2; }
warn()  { echo "[warn] $*" >&2; }
die()   { echo "[error] $*" >&2; exit 1; }

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)          MODE="list" ;;
    --tui)           MODE="tui" ;;
    --json)          JSON_MODE=true ;;
    --mark-read)     MODE="mark-read"; MARK_READ_ID="${2:-}"; [[ -n "${2:-}" ]] && shift ;;
    --snooze)        MODE="snooze"; SNOOZE_ID="${2:?--snooze requires ID}"; SNOOZE_HOURS="${3:?--snooze requires HOURS}"; shift 2 ;;
    --open)          MODE="open"; OPEN_ID="${2:?--open requires ID}"; shift ;;
    --filter)        FILTER_TYPE="${2:?--filter requires TYPE}"; shift ;;
    --filter-repo)   FILTER_REPO="${2:?--filter-repo requires REPO}"; shift ;;
    --auto-triage)   AUTO_TRIAGE=true ;;
    --scope)         SCOPE="${2:?--scope requires SCOPE}"; shift ;;
    --limit)         LIMIT="${2:?--limit requires N}"; shift ;;
    --serve)         SERVE=true ;;
    --help|-h)
      sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
  shift
done

API="https://api.github.com"

# ── API helpers ───────────────────────────────────────────────────────────────
_api_get() {
  local url="$1"
  curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$url" 2>/dev/null || echo "[]"
}

_api_patch() {
  local url="$1" data="${2:-{}}"
  curl -sf -X PATCH \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -d "$data" \
    "$url" 2>/dev/null
}

_api_put() {
  local url="$1" data="${2:-{}}"
  curl -sf -X PUT \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -d "$data" \
    "$url" 2>/dev/null
}

_api_delete() {
  local url="$1"
  curl -sf -X DELETE \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$url" 2>/dev/null
}

# ── Fetch notifications ───────────────────────────────────────────────────────
fetch_notifications() {
  local all_flag="false"
  [[ "$SCOPE" == "all" ]] && all_flag="true"

  local url="${API}/notifications?all=${all_flag}&participating=false&per_page=${LIMIT}"
  [[ "$SCOPE" == "participating" ]] && url="${API}/notifications?all=false&participating=true&per_page=${LIMIT}"

  _api_get "$url"
}

# ── Filter notifications ──────────────────────────────────────────────────────
filter_notifications() {
  local json="$1"
  local py_filter=""

  # Build Python filter expression
  if [[ "$FILTER_TYPE" != "all" ]]; then
    py_filter+="n['reason'] == '${FILTER_TYPE}' and "
  fi
  if [[ -n "$FILTER_REPO" ]]; then
    py_filter+="'${FILTER_REPO}' in n['repository']['name'] and "
  fi
  # Strip trailing " and "
  py_filter="${py_filter% and }"
  [[ -z "$py_filter" ]] && py_filter="True"

  echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
filtered = [n for n in data if ${py_filter}]
print(json.dumps(filtered))
" 2>/dev/null || echo "[]"
}

# ── Format for display ────────────────────────────────────────────────────────
format_notifications() {
  local json="$1"
  echo "$json" | python3 -c "
import json, sys
from datetime import datetime, timezone

data = json.load(sys.stdin)
if not data:
    print('  No notifications.')
    sys.exit(0)

# ANSI colours
RESET  = '\033[0m'
BOLD   = '\033[1m'
DIM    = '\033[2m'
RED    = '\033[31m'
YELLOW = '\033[33m'
CYAN   = '\033[36m'
GREEN  = '\033[32m'
BLUE   = '\033[34m'

REASON_COLOUR = {
    'ci_activity':        RED,
    'mention':            YELLOW,
    'review_requested':   CYAN,
    'assign':             GREEN,
    'author':             BLUE,
    'comment':            BLUE,
    'subscribed':         DIM,
    'team_mention':       YELLOW,
    'security_alert':     RED,
}

for n in data:
    nid     = n['id']
    repo    = n['repository']['full_name']
    subject = n['subject']['title']
    reason  = n['reason']
    stype   = n['subject']['type']
    updated = n.get('updated_at', '')

    # Relative time
    try:
        dt = datetime.fromisoformat(updated.replace('Z', '+00:00'))
        delta = datetime.now(timezone.utc) - dt
        mins = int(delta.total_seconds() / 60)
        if mins < 60:
            age = f'{mins}m ago'
        elif mins < 1440:
            age = f'{mins // 60}h ago'
        else:
            age = f'{mins // 1440}d ago'
    except Exception:
        age = updated[:10]

    colour = REASON_COLOUR.get(reason, DIM)
    print(f'{BOLD}{nid}{RESET}  {colour}{reason:<20}{RESET}  {DIM}{age:<10}{RESET}  {BOLD}{repo}{RESET}')
    print(f'  {DIM}{stype}{RESET}  {subject}')
    print()
" 2>/dev/null
}

# ── Auto-triage: mark known-safe patterns as read ─────────────────────────────
auto_triage() {
  local json="$1"
  local marked=0

  # Known-safe patterns — title substrings that are noise, not actionable
  local -a safe_patterns=(
    "Mirror to OpenOS-Project-OSP"
    "Sync btrfs-devel Branches"
    "Rate limit"
    "rate limit"
    "Quota"
    "quota exhausted"
    "Dependabot"
    "chore(deps)"
    "chore: bump"
    "build(deps)"
  )

  local ids
  ids=$(echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
patterns = $(printf '%s\n' "${safe_patterns[@]}" | python3 -c "import sys,json; print(json.dumps([l.rstrip() for l in sys.stdin]))")
for n in data:
    title = n['subject']['title']
    if any(p in title for p in patterns):
        print(n['id'])
" 2>/dev/null)

  if [[ -z "$ids" ]]; then
    info "Auto-triage: no known-safe notifications found."
    return 0
  fi

  while IFS= read -r nid; do
    [[ -z "$nid" ]] && continue
    _api_patch "${API}/notifications/threads/${nid}" >/dev/null
    info "Auto-triaged: $nid"
    (( marked++ )) || true
  done <<< "$ids"

  info "Auto-triage: marked ${marked} notification(s) as read."
}

# ── Mark read ─────────────────────────────────────────────────────────────────
mark_read() {
  local id="$1"
  if [[ -z "$id" ]]; then
    info "Marking all notifications as read..."
    _api_put "${API}/notifications" '{"read":true}' >/dev/null
    info "Done."
  else
    _api_patch "${API}/notifications/threads/${id}" >/dev/null
    info "Marked ${id} as read."
  fi
}

# ── Snooze (GitHub doesn't have native snooze; we mark read + log) ────────────
snooze() {
  local id="$1" hours="$2"
  local wake_at
  wake_at=$(date -u -d "+${hours} hours" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -v "+${hours}H" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || echo "unknown")
  info "Snoozing ${id} for ${hours}h (wake at ${wake_at}) — marking read now."
  _api_patch "${API}/notifications/threads/${id}" >/dev/null
  # Log snooze to a local file so the web UI can surface it
  local snooze_file="${HOME}/.local/share/fsa-notifications/snooze.json"
  mkdir -p "$(dirname "$snooze_file")"
  local existing="[]"
  [[ -f "$snooze_file" ]] && existing=$(cat "$snooze_file")
  echo "$existing" | python3 -c "
import json, sys
data = json.load(sys.stdin)
data.append({'id': '${id}', 'wake_at': '${wake_at}', 'hours': ${hours}})
print(json.dumps(data, indent=2))
" > "$snooze_file"
  info "Snooze logged to ${snooze_file}"
}

# ── Open in browser ───────────────────────────────────────────────────────────
open_notification() {
  local id="$1"
  local thread_url
  thread_url=$(_api_get "${API}/notifications/threads/${id}" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('subject',{}).get('url',''))" 2>/dev/null)

  # Convert API URL to HTML URL
  local html_url
  html_url=$(echo "$thread_url" | sed \
    -e 's|api\.github\.com/repos/|github.com/|' \
    -e 's|/pulls/|/pull/|' \
    -e 's|/commits/|/commit/|')

  if [[ -z "$html_url" ]]; then
    warn "Could not resolve URL for notification ${id}"
    return 1
  fi

  info "Opening: ${html_url}"
  local browser="${BROWSER:-}"
  if [[ -z "$browser" ]]; then
    if command -v xdg-open &>/dev/null; then browser="xdg-open"
    elif command -v open &>/dev/null; then browser="open"
    else
      info "No browser found. URL: ${html_url}"
      return 0
    fi
  fi
  "$browser" "$html_url" &>/dev/null &
}

# ── TUI via fzf ───────────────────────────────────────────────────────────────
run_tui() {
  if ! command -v fzf &>/dev/null; then
    die "fzf is required for --tui mode. Install with: sudo apt-get install fzf"
  fi

  local json
  json=$(fetch_notifications)
  json=$(filter_notifications "$json")

  if [[ "$(echo "$json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)" == "0" ]]; then
    info "No notifications to display."
    return 0
  fi

  # Build fzf input: "ID | REASON | REPO | TITLE"
  local fzf_input
  fzf_input=$(echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for n in data:
    nid    = n['id']
    reason = n['reason']
    repo   = n['repository']['full_name']
    title  = n['subject']['title']
    print(f'{nid} | {reason:<20} | {repo:<45} | {title}')
" 2>/dev/null)

  local header
  header="ENTER=open  ctrl-r=mark-read  ctrl-a=mark-all-read  ctrl-t=auto-triage  ESC=quit"

  local selected
  selected=$(echo "$fzf_input" | fzf \
    --ansi \
    --multi \
    --header="$header" \
    --prompt="notifications> " \
    --preview="echo {} | cut -d'|' -f1 | xargs -I{ID} bash -c 'source ${SCRIPT_DIR}/notifications.sh 2>/dev/null; GH_TOKEN=${GH_TOKEN} _api_get ${API}/notifications/threads/{ID} | python3 -c \"import json,sys; d=json.load(sys.stdin); print(d.get(\\\"subject\\\",{}).get(\\\"title\\\",\\\"\\\")); print(d.get(\\\"repository\\\",{}).get(\\\"full_name\\\",\\\"\\\"))\"'" \
    --bind "ctrl-r:execute-silent(echo {} | cut -d'|' -f1 | tr -d ' ' | xargs -I{ID} curl -sf -X PATCH -H 'Authorization: token ${GH_TOKEN}' -H 'Accept: application/vnd.github+json' '${API}/notifications/threads/{ID}')+reload(echo '$fzf_input')" \
    --bind "ctrl-a:execute-silent(curl -sf -X PUT -H 'Authorization: token ${GH_TOKEN}' -H 'Accept: application/vnd.github+json' '${API}/notifications' -d '{\"read\":true}')+abort" \
    --bind "ctrl-t:execute-silent(bash -c 'GH_TOKEN=${GH_TOKEN} AUTO_TRIAGE=true ${SCRIPT_DIR}/notifications.sh --auto-triage')+reload(echo '$fzf_input')" \
    2>/dev/null) || true

  if [[ -n "$selected" ]]; then
    local nid
    nid=$(echo "$selected" | head -1 | cut -d'|' -f1 | tr -d ' ')
    open_notification "$nid"
  fi
}

# ── Web UI server ─────────────────────────────────────────────────────────────
run_server() {
  local ui_dir="${SCRIPT_DIR}/../vendor/notifications-ui"
  if [[ ! -d "$ui_dir" ]]; then
    die "Web UI not found at ${ui_dir}. Run from the fork-sync-all root."
  fi
  info "Starting notifications web UI on http://localhost:${WEB_PORT}"
  info "Press Ctrl+C to stop."

  # Serve the UI and proxy API calls via a simple Python server
  python3 - <<PYEOF
import http.server, urllib.request, urllib.error, json, os, sys

PORT = ${WEB_PORT}
UI_DIR = os.path.realpath('${ui_dir}')
TOKEN = '${GH_TOKEN}'
API_BASE = 'https://api.github.com'

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=UI_DIR, **kwargs)

    def do_GET(self):
        if self.path.startswith('/api/'):
            self._proxy(self.path[4:])
        else:
            super().do_GET()

    def do_PATCH(self):
        if self.path.startswith('/api/'):
            self._proxy(self.path[4:], method='PATCH')

    def do_PUT(self):
        if self.path.startswith('/api/'):
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length) if length else b'{}'
            self._proxy(self.path[4:], method='PUT', body=body)

    def do_DELETE(self):
        if self.path.startswith('/api/'):
            self._proxy(self.path[4:], method='DELETE')

    def _proxy(self, path, method='GET', body=None):
        url = API_BASE + path
        req = urllib.request.Request(url, method=method, data=body)
        req.add_header('Authorization', f'token {TOKEN}')
        req.add_header('Accept', 'application/vnd.github+json')
        if body:
            req.add_header('Content-Type', 'application/json')
        try:
            with urllib.request.urlopen(req) as resp:
                data = resp.read()
                self.send_response(resp.status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(data)
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(e.read())

    def log_message(self, fmt, *args):
        pass  # suppress request logs

print(f'Notifications UI: http://localhost:{PORT}', flush=True)
with http.server.HTTPServer(('', PORT), Handler) as httpd:
    httpd.serve_forever()
PYEOF
}

# ── Summary for workflow step summary ─────────────────────────────────────────
print_summary() {
  local json="$1"
  echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
total = len(data)
by_reason = {}
by_repo = {}
for n in data:
    r = n['reason']
    repo = n['repository']['full_name']
    by_reason[r] = by_reason.get(r, 0) + 1
    by_repo[repo] = by_repo.get(repo, 0) + 1

print(f'## Notifications Summary')
print(f'')
print(f'**Total unread:** {total}')
print(f'')
print(f'### By type')
for reason, count in sorted(by_reason.items(), key=lambda x: -x[1]):
    print(f'- \`{reason}\`: {count}')
print(f'')
print(f'### By repo (top 10)')
for repo, count in sorted(by_repo.items(), key=lambda x: -x[1])[:10]:
    print(f'- \`{repo}\`: {count}')
" 2>/dev/null
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  if [[ "$SERVE" == "true" ]]; then
    run_server
    return
  fi

  case "$MODE" in
    mark-read)
      mark_read "$MARK_READ_ID"
      return
      ;;
    snooze)
      snooze "$SNOOZE_ID" "$SNOOZE_HOURS"
      return
      ;;
    open)
      open_notification "$OPEN_ID"
      return
      ;;
    tui)
      run_tui
      return
      ;;
  esac

  # list mode (default)
  local json
  json=$(fetch_notifications)
  json=$(filter_notifications "$json")

  if [[ "$AUTO_TRIAGE" == "true" ]]; then
    auto_triage "$json"
    # Re-fetch after triage
    json=$(fetch_notifications)
    json=$(filter_notifications "$json")
  fi

  if [[ "$JSON_MODE" == "true" ]]; then
    echo "$json"
    return
  fi

  # Check if running in a GitHub Actions context — emit step summary
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    print_summary "$json" >> "$GITHUB_STEP_SUMMARY"
  fi

  format_notifications "$json"
}

main "$@"
