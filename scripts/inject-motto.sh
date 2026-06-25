#!/usr/bin/env bash
# scripts/inject-motto.sh — inject repo motto/slogan into README.md files
#
# Reads config/fsa-motto.yml. For each repo in the configured orgs:
#   1. Fetches README.md
#   2. Checks for existing FSA-MOTTO-START/END markers (preserves if present)
#   3. Injects the motto as a blockquote after the badge line
#   4. Commits and pushes if changed
#
# Motto placement: after the badge line (first non-empty line after # heading),
# before the description paragraph.
#
# Idempotent: skips repos where the motto text is already present.
#
# Required env:
#   GH_TOKEN   — PAT with repo scope
#
# Optional env:
#   REPO_FILTER — substring filter on repo name
#   DRY_RUN     — "true" to skip commits
#   ORGS        — space-separated org list (default: Interested-Deving-1896)
#   REPO_SINGLE — process only this "owner/repo" (for targeted runs)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/includes/gh-api.sh"

info() { echo "[inject-motto] $*" >&2; }
warn() { echo "[inject-motto][warn] $*" >&2; }
dry()  { echo "[inject-motto][dry-run] $*" >&2; }

MOTTO_CFG="$REPO_ROOT/config/fsa-motto.yml"
REPO_FILTER="${REPO_FILTER:-}"
DRY_RUN="${DRY_RUN:-false}"
ORGS="${ORGS:-Interested-Deving-1896}"
REPO_SINGLE="${REPO_SINGLE:-}"

[[ -f "$MOTTO_CFG" ]] || { warn "config/fsa-motto.yml not found"; exit 0; }

# ── Load default motto ────────────────────────────────────────────────────────
default_enabled=$(python3 -c "
import yaml
with open('$MOTTO_CFG') as f: c = yaml.safe_load(f)
print(str(c.get('default',{}).get('enabled', False)).lower())
" 2>/dev/null)

[[ "$default_enabled" == "true" ]] || { info "motto injection disabled — skipping"; exit 0; }

default_text=$(python3 -c "
import yaml
with open('$MOTTO_CFG') as f: c = yaml.safe_load(f)
print(c.get('default',{}).get('text',''))
" 2>/dev/null)

default_format=$(python3 -c "
import yaml
with open('$MOTTO_CFG') as f: c = yaml.safe_load(f)
print(c.get('default',{}).get('format','blockquote'))
" 2>/dev/null)

# ── Format motto text ─────────────────────────────────────────────────────────
format_motto() {
  local text="$1" fmt="$2"
  case "$fmt" in
    blockquote) echo "> ${text}" ;;
    italic)     echo "*${text}*" ;;
    bold)       echo "**${text}**" ;;
    *)          echo "${text}" ;;
  esac
}

# ── Get per-repo motto override ───────────────────────────────────────────────
get_repo_motto() {
  local owner_repo="$1"
  python3 - "$MOTTO_CFG" "$owner_repo" << 'PYEOF'
import yaml, sys

cfg_file, owner_repo = sys.argv[1:]
with open(cfg_file) as f:
    cfg = yaml.safe_load(f)

repos = cfg.get('repos', []) or []
for r in repos:
    if r.get('repo') == owner_repo:
        text = r.get('text', '')
        fmt  = r.get('format', cfg.get('default', {}).get('format', 'blockquote'))
        print(f"{text}|||{fmt}")
        sys.exit(0)

# Fall back to default
d = cfg.get('default', {})
print(f"{d.get('text','')}|||{d.get('format','blockquote')}")
PYEOF
}

# ── Inject motto into README content ─────────────────────────────────────────
# Inserts after the badge line (first non-heading, non-empty line after # heading)
# Preserves FSA-MOTTO-START/END markers if present.
inject_motto_content() {
  local content="$1" motto_line="$2"

  # If markers already exist, replace content between them
  if echo "$content" | grep -q "FSA-MOTTO-START"; then
    echo "$content" | python3 -c "
import sys, re
content = sys.stdin.read()
motto = '''$motto_line'''
pattern = r'<!-- FSA-MOTTO-START -->.*?<!-- FSA-MOTTO-END -->'
replacement = f'<!-- FSA-MOTTO-START -->\n{motto}\n<!-- FSA-MOTTO-END -->'
print(re.sub(pattern, replacement, content, flags=re.DOTALL))
" 2>/dev/null
    return
  fi

  # No markers: inject after badge line (second non-empty line after # heading)
  echo "$content" | python3 -c "
import sys
lines = sys.stdin.read().splitlines()
motto = '''$motto_line'''
output = []
heading_seen = False
badge_seen = False
inserted = False

for line in lines:
    output.append(line)
    if not inserted:
        if line.startswith('# ') and not heading_seen:
            heading_seen = True
        elif heading_seen and not badge_seen:
            # Badge line: non-empty line after heading
            if line.strip() and not line.startswith('#'):
                badge_seen = True
        elif badge_seen and not inserted:
            # Insert motto after badge line (skip blank lines between badge and motto)
            if line.strip() == '':
                continue
            # Insert before this line
            output.pop()  # remove current line temporarily
            output.append('')
            output.append(motto)
            output.append('')
            output.append(line)
            inserted = True

if not inserted and heading_seen:
    output.append('')
    output.append(motto)

print('\n'.join(output))
" 2>/dev/null
}

# ── Process a single repo ─────────────────────────────────────────────────────
process_repo() {
  local owner="$1" repo="$2"
  local owner_repo="${owner}/${repo}"

  [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]] && return 0

  local meta
  meta=$(gh_get "${GH_API}/repos/${owner}/${repo}/contents/README.md" 2>/dev/null) || return 0
  [[ -z "$meta" || "$meta" == "null" ]] && return 0
  echo "$meta" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if 'sha' in d else 1)" 2>/dev/null || return 0

  local sha content
  sha=$(echo "$meta" | python3 -c "import json,sys; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null)
  content=$(echo "$meta" | python3 -c "import json,sys; import base64; print(base64.b64decode(json.load(sys.stdin).get('content','').replace('\n','')).decode('utf-8','replace'))" 2>/dev/null)
  [[ -z "$content" ]] && return 0

  # Get motto for this repo
  local motto_raw motto_text motto_fmt motto_line
  motto_raw=$(get_repo_motto "$owner_repo")
  motto_text="${motto_raw%%|||*}"
  motto_fmt="${motto_raw##*|||}"
  [[ -z "$motto_text" ]] && return 0

  motto_line=$(format_motto "$motto_text" "$motto_fmt")

  # Skip if already present
  if echo "$content" | grep -qF "$motto_text"; then
    info "  SKIP ${owner_repo} (motto already present)"
    return 0
  fi

  local new_content
  new_content=$(inject_motto_content "$content" "$motto_line")

  if [[ "$new_content" == "$content" ]]; then
    info "  SKIP ${owner_repo} (no change)"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "  Would inject motto into ${owner_repo}/README.md"
    dry "    Motto: ${motto_line}"
    return 0
  fi

  local new_b64 payload
  new_b64=$(echo "$new_content" | base64 -w0)
  payload=$(python3 -c "
import json
print(json.dumps({
  'message': 'docs: add repo motto [skip ci]',
  'content': '$new_b64',
  'sha': '$sha',
  'committer': {
    'name': 'github-actions[bot]',
    'email': 'github-actions[bot]@users.noreply.github.com',
  },
}))
")

  local result
  result=$(curl -sf -X PUT \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    "${GH_API}/repos/${owner}/${repo}/contents/README.md" \
    -d "$payload" 2>/dev/null || echo '{"message":"failed"}')

  if echo "$result" | python3 -c "import json,sys; sys.exit(0 if 'commit' in json.load(sys.stdin) else 1)" 2>/dev/null; then
    info "  UPDATED ${owner_repo}/README.md"
  else
    local err; err=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('message','unknown'))" 2>/dev/null)
    warn "  FAILED ${owner_repo}: ${err}"
  fi
}

# ── Main loop ─────────────────────────────────────────────────────────────────
if [[ -n "$REPO_SINGLE" ]]; then
  owner="${REPO_SINGLE%%/*}"
  repo="${REPO_SINGLE##*/}"
  process_repo "$owner" "$repo"
  exit 0
fi

for org in $ORGS; do
  info "processing org: ${org}"
  repos=$(gh_get "${GH_API}/orgs/${org}/repos?per_page=100&type=all" \
    | python3 -c "import json,sys; [print(r['name']) for r in json.load(sys.stdin)]" 2>/dev/null || echo "")
  [[ -z "$repos" ]] && continue
  while IFS= read -r repo; do
    process_repo "$org" "$repo"
  done <<< "$repos"
done

info "done"
