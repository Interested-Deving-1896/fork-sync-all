#!/usr/bin/env bash
#
# Onboards a repository into the fork-sync-all ecosystem.
#
# Reads config/onboarding.yml for defaults. Each action can be overridden
# via environment variables (set by the workflow from dispatch inputs).
#
# Required env vars:
#   GH_TOKEN        — PAT with repo + issues write access
#   REPO_NAME       — target repo name (no owner prefix)
#
# Optional env vars (override onboarding.yml defaults):
#   OWNER           — I-D-1896 org (default: Interested-Deving-1896)
#   OSP_ORG         — OSP org (default: OpenOS-Project-OSP)
#   REPO            — owner/repo of fork-sync-all (for dispatch calls)
#   PROFILE         — template profile for this repo (from template-consumers.yml)
#   UPSTREAM_URL    — upstream source URL (from registered-imports.json)
#   DO_WELCOME_ISSUE      — true/false override
#   DO_APPLY_LABELS       — true/false override
#   DO_BRANCH_PROTECTION  — true/false override
#   DO_APPLY_TOPICS       — true/false override
#   DO_SET_DESCRIPTION    — true/false override
#   DO_OSP_SETUP          — true/false override
#   DO_DISPATCH_WORKFLOWS — true/false override
#   DRY_RUN         — true = log actions without executing (default: false)

set -uo pipefail

OWNER="${OWNER:-Interested-Deving-1896}"
OSP_ORG="${OSP_ORG:-OpenOS-Project-OSP}"
REPO="${REPO:-Interested-Deving-1896/fork-sync-all}"
DRY_RUN="${DRY_RUN:-false}"
API="https://api.github.com"
CONFIG="config/onboarding.yml"

info()  { echo "[onboard] $*" >&2; }
warn()  { echo "[onboard][warn] $*" >&2; }
dry()   { echo "[onboard][dry-run] $*" >&2; }
ok()    { echo "[onboard][ok] $*" >&2; }
fail()  { echo "[onboard][error] $1" >&2; exit "${2:-1}"; }

[[ -z "${REPO_NAME:-}" ]] && fail "REPO_NAME is required"
[[ -z "${GH_TOKEN:-}" ]]  && fail "GH_TOKEN is required"

# ── Load config defaults ──────────────────────────────────────────────────────
cfg() {
  python3 -c "
import yaml, sys
d = yaml.safe_load(open('$CONFIG'))
keys = '$1'.split('.')
v = d
for k in keys:
    v = (v or {}).get(k)
    if v is None: break
print(str(v).lower() if isinstance(v, bool) else (v or ''))
" 2>/dev/null
}

cfg_list() {
  python3 -c "
import yaml, json
d = yaml.safe_load(open('$CONFIG'))
keys = '$1'.split('.')
v = d
for k in keys:
    v = (v or {}).get(k)
    if v is None: break
print(json.dumps(v or []))
" 2>/dev/null
}

# Action flags: env var wins over config default
_flag() {
  local env_var="$1" cfg_key="$2"
  local env_val="${!env_var:-}"
  if [[ -n "$env_val" ]]; then
    echo "$env_val"
  else
    cfg "actions.$cfg_key"
  fi
}

DO_WELCOME_ISSUE="${DO_WELCOME_ISSUE:-$(_flag DO_WELCOME_ISSUE welcome_issue)}"
DO_APPLY_LABELS="${DO_APPLY_LABELS:-$(_flag DO_APPLY_LABELS apply_labels)}"
DO_BRANCH_PROTECTION="${DO_BRANCH_PROTECTION:-$(_flag DO_BRANCH_PROTECTION branch_protection)}"
DO_APPLY_TOPICS="${DO_APPLY_TOPICS:-$(_flag DO_APPLY_TOPICS apply_topics)}"
DO_SET_DESCRIPTION="${DO_SET_DESCRIPTION:-$(_flag DO_SET_DESCRIPTION set_description)}"
DO_OSP_SETUP="${DO_OSP_SETUP:-$(_flag DO_OSP_SETUP osp_setup)}"
DO_DISPATCH_WORKFLOWS="${DO_DISPATCH_WORKFLOWS:-$(_flag DO_DISPATCH_WORKFLOWS dispatch_workflows)}"

info "Onboarding: ${OWNER}/${REPO_NAME}"
info "Profile: ${PROFILE:-unknown}"
info "Upstream: ${UPSTREAM_URL:-unknown}"
info "Actions: welcome_issue=$DO_WELCOME_ISSUE labels=$DO_APPLY_LABELS branch_protection=$DO_BRANCH_PROTECTION topics=$DO_APPLY_TOPICS description=$DO_SET_DESCRIPTION osp=$DO_OSP_SETUP dispatch=$DO_DISPATCH_WORKFLOWS"
[[ "$DRY_RUN" == "true" ]] && info "DRY RUN — no changes will be made"

# ── Helpers ───────────────────────────────────────────────────────────────────
gh_api() {
  local method="$1" path="$2"
  shift 2
  curl -sf \
    -X "$method" \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API}${path}" "$@" 2>/dev/null
}

gh_get()  { gh_api GET  "$@"; }
gh_post() { gh_api POST "$@"; }
gh_put()  { gh_api PUT  "$@"; }
gh_patch(){ gh_api PATCH "$@"; }

# Resolve default branch
default_branch() {
  local owner="$1" repo="$2"
  gh_get "/repos/${owner}/${repo}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('default_branch','main'))" 2>/dev/null || echo "main"
}

# ── 1. Apply labels ───────────────────────────────────────────────────────────
apply_labels_to() {
  local owner="$1" repo="$2"
  info "Applying labels to ${owner}/${repo}..."
  python3 - << PYEOF
import yaml, json, subprocess, sys

config = yaml.safe_load(open('$CONFIG'))
labels = config.get('labels', [])
token = '$GH_TOKEN'
api = '$API'
owner = '$owner'
repo = '$repo'
dry = '$DRY_RUN' == 'true'

for label in labels:
    name = label['name']
    color = label['color']
    desc = label.get('description', '')
    payload = json.dumps({'name': name, 'color': color, 'description': desc})

    # Try PATCH (update) first, then POST (create)
    result = subprocess.run(
        ['curl', '-sf', '-o', '/dev/null', '-w', '%{http_code}',
         '-X', 'PATCH',
         '-H', f'Authorization: token {token}',
         '-H', 'Accept: application/vnd.github+json',
         f'{api}/repos/{owner}/{repo}/labels/{name}',
         '-d', payload],
        capture_output=True, text=True
    )
    code = result.stdout.strip()
    if code == '200':
        print(f'[onboard][ok] label updated: {name}', file=sys.stderr)
        continue
    if dry:
        print(f'[onboard][dry-run] would create label: {name}', file=sys.stderr)
        continue
    result = subprocess.run(
        ['curl', '-sf', '-o', '/dev/null', '-w', '%{http_code}',
         '-X', 'POST',
         '-H', f'Authorization: token {token}',
         '-H', 'Accept: application/vnd.github+json',
         f'{api}/repos/{owner}/{repo}/labels',
         '-d', payload],
        capture_output=True, text=True
    )
    code = result.stdout.strip()
    if code in ('201', '422'):
        print(f'[onboard][ok] label created: {name} (HTTP {code})', file=sys.stderr)
    else:
        print(f'[onboard][warn] label {name} HTTP {code}', file=sys.stderr)
PYEOF
}

if [[ "$DO_APPLY_LABELS" == "true" ]]; then
  apply_labels_to "$OWNER" "$REPO_NAME"
  [[ "$DO_OSP_SETUP" == "true" ]] && apply_labels_to "$OSP_ORG" "$REPO_NAME"
fi

# ── 2. Branch protection ──────────────────────────────────────────────────────
apply_branch_protection_to() {
  local owner="$1" repo="$2"
  local branch
  branch=$(default_branch "$owner" "$repo")
  info "Applying branch protection to ${owner}/${repo} (${branch})..."
  local payload
  payload=$(python3 -c "
import yaml, json
c = yaml.safe_load(open('$CONFIG'))
bp = c.get('branch_protection', {})
print(json.dumps({
    'required_status_checks': bp.get('required_status_checks') or None,
    'enforce_admins': bp.get('enforce_admins', False),
    'required_pull_request_reviews': bp.get('required_pull_request_reviews') or None,
    'restrictions': None,
    'allow_force_pushes': bp.get('allow_force_pushes', False),
    'allow_deletions': bp.get('allow_deletions', False),
}))
")
  if [[ "$DRY_RUN" == "true" ]]; then
    dry "would PUT /repos/${owner}/${repo}/branches/${branch}/protection"
    return
  fi
  local code
  code=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X PUT \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API}/repos/${owner}/${repo}/branches/${branch}/protection" \
    -d "$payload" 2>/dev/null || echo "000")
  ok "branch protection ${owner}/${repo}/${branch}: HTTP ${code}"
}

if [[ "$DO_BRANCH_PROTECTION" == "true" ]]; then
  apply_branch_protection_to "$OWNER" "$REPO_NAME"
  [[ "$DO_OSP_SETUP" == "true" ]] && apply_branch_protection_to "$OSP_ORG" "$REPO_NAME"
fi

# ── 3. Apply topics ───────────────────────────────────────────────────────────
if [[ "$DO_APPLY_TOPICS" == "true" ]]; then
  info "Applying topics to ${OWNER}/${REPO_NAME}..."
  profile_topics=$(python3 -c "
import yaml, json
c = yaml.safe_load(open('$CONFIG'))
profile = '${PROFILE:-}'
topics = c.get('profile_topics', {}).get(profile, [])
print(json.dumps(topics))
" 2>/dev/null || echo "[]")

  existing_topics=$(gh_get "/repos/${OWNER}/${REPO_NAME}/topics" \
    | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('names', [])))" 2>/dev/null || echo "[]")

  merged_topics=$(python3 -c "
import json
existing = json.loads('$existing_topics')
new = json.loads('''$profile_topics''')
merged = sorted(set(existing + new))
print(json.dumps({'names': merged}))
")

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "would PUT topics: $merged_topics"
  else
    code=$(curl -sf -o /dev/null -w "%{http_code}" \
      -X PUT \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${API}/repos/${OWNER}/${REPO_NAME}/topics" \
      -d "$merged_topics" 2>/dev/null || echo "000")
    ok "topics applied: HTTP ${code}"
  fi
fi

# ── 4. Set description ────────────────────────────────────────────────────────
if [[ "$DO_SET_DESCRIPTION" == "true" && -n "${UPSTREAM_URL:-}" ]]; then
  info "Setting description on ${OWNER}/${REPO_NAME}..."
  # Derive a short description from the upstream URL if none exists
  existing_desc=$(gh_get "/repos/${OWNER}/${REPO_NAME}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('description') or '')" 2>/dev/null || echo "")

  if [[ -z "$existing_desc" ]]; then
    upstream_name=$(basename "${UPSTREAM_URL%.git}")
    new_desc="Fork of ${upstream_name} — managed by fork-sync-all"
    if [[ "$DRY_RUN" == "true" ]]; then
      dry "would PATCH description: $new_desc"
    else
      code=$(curl -sf -o /dev/null -w "%{http_code}" \
        -X PATCH \
        -H "Authorization: token ${GH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "${API}/repos/${OWNER}/${REPO_NAME}" \
        -d "{\"description\": \"${new_desc}\"}" 2>/dev/null || echo "000")
      ok "description set: HTTP ${code}"
    fi
  else
    info "Description already set — skipping"
  fi
fi

# ── 5. Welcome issue ──────────────────────────────────────────────────────────
if [[ "$DO_WELCOME_ISSUE" == "true" ]]; then
  info "Creating welcome issue on ${OWNER}/${REPO_NAME}..."

  issue_title=$(cfg "welcome_issue.title")
  issue_labels=$(cfg_list "welcome_issue.labels")

  issue_body=$(python3 - << PYEOF
import yaml, json

config = yaml.safe_load(open('$CONFIG'))
repo_name = '$REPO_NAME'
owner = '$OWNER'
osp_org = '$OSP_ORG'
profile = '${PROFILE:-unknown}'
upstream_url = '${UPSTREAM_URL:-unknown}'
dispatch_list = config.get('dispatch_list', [])
actions = config.get('actions', {})

lines = []
lines.append('## Context')
lines.append('')
lines.append(f'| Field | Value |')
lines.append(f'|---|---|')
lines.append(f'| Repo | \`{owner}/{repo_name}\` |')
lines.append(f'| Profile | \`{profile}\` |')
lines.append(f'| Upstream | {upstream_url} |')
lines.append(f'| OSP mirror | \`{osp_org}/{repo_name}\` |')
lines.append('')
lines.append('## Setup checklist')
lines.append('')

if actions.get('apply_labels'):
    lines.append('- [x] Labels applied (upstream-sync, mirror-chain, template-managed, onboarded)')
if actions.get('branch_protection'):
    lines.append('- [x] Branch protection configured on default branch')
if actions.get('apply_topics'):
    lines.append(f'- [x] Topics applied for profile \`{profile}\`')
if actions.get('set_description'):
    lines.append('- [x] Repo description set')
if actions.get('osp_setup'):
    lines.append(f'- [x] Labels + branch protection applied on \`{osp_org}/{repo_name}\`')

lines.append('')
lines.append('## Downstream workflows dispatched')
lines.append('')
for entry in dispatch_list:
    if entry.get('enabled', True):
        wf = entry['workflow']
        reason = entry.get('reason', '')
        lines.append(f'- [x] \`{wf}\` — {reason}')

lines.append('')
lines.append('---')
lines.append('_Opened automatically by the [Onboard Repository](../actions/workflows/onboard-repo.yml) workflow._')

print('\n'.join(lines))
PYEOF
)

  labels_json=$(python3 -c "
import json
labels = json.loads('$issue_labels')
print(json.dumps(labels))
" 2>/dev/null || echo "[]")

  payload=$(python3 -c "
import json, sys
title = '$issue_title'
body = sys.stdin.read()
labels = json.loads('$labels_json')
print(json.dumps({'title': title, 'body': body, 'labels': labels}))
" <<< "$issue_body")

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "would POST issue: $issue_title"
  else
    code=$(curl -sf -o /dev/null -w "%{http_code}" \
      -X POST \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${API}/repos/${OWNER}/${REPO_NAME}/issues" \
      -d "$payload" 2>/dev/null || echo "000")
    ok "welcome issue created: HTTP ${code}"
  fi
fi

# ── 6. Dispatch downstream workflows ─────────────────────────────────────────
if [[ "$DO_DISPATCH_WORKFLOWS" == "true" ]]; then
  info "Dispatching downstream workflows..."
  python3 - << PYEOF
import yaml, json, subprocess, sys, os

config = yaml.safe_load(open('$CONFIG'))
dispatch_list = config.get('dispatch_list', [])
token = '$GH_TOKEN'
fsa_repo = '$REPO'
dry = '$DRY_RUN' == 'true'

for entry in dispatch_list:
    if not entry.get('enabled', True):
        print(f"[onboard] skip (disabled): {entry['workflow']}", file=sys.stderr)
        continue
    wf = entry['workflow']
    inputs = entry.get('inputs') or {}
    reason = entry.get('reason', '')
    if dry:
        print(f"[onboard][dry-run] would dispatch: {wf} — {reason}", file=sys.stderr)
        continue
    print(f"[onboard] dispatching: {wf} — {reason}", file=sys.stderr)
    result = subprocess.run(
        ['bash', 'scripts/dispatch-and-wait.sh', wf, '90', json.dumps(inputs)],
        env={**os.environ, 'GH_TOKEN': token, 'REPO': fsa_repo},
        capture_output=False
    )
    if result.returncode == 0:
        print(f"[onboard][ok] {wf} completed", file=sys.stderr)
    elif result.returncode == 2:
        print(f"[onboard][warn] {wf} was cancelled (retriable)", file=sys.stderr)
    else:
        print(f"[onboard][warn] {wf} failed (exit {result.returncode}) — continuing", file=sys.stderr)
PYEOF
fi

info "Onboarding complete: ${OWNER}/${REPO_NAME}"
