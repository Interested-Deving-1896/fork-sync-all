#!/usr/bin/env bash
#
# manage-repo-settings.sh
#
# Declarative repo settings management with drift detection.
# Reads a YAML settings file and either checks for drift (check mode)
# or enforces the declared state (apply mode) across all OSP-bound repos
# or a filtered subset.
#
# Inspired by andrewthetechie/gha-repo-manager — reimplemented as a
# fork-sync-all shell script using the existing gh-api.sh + budget.sh
# infrastructure and the GitHub REST API directly.
#
# ── Settings file format ──────────────────────────────────────────────────────
#
# Default location: config/repo-settings.yml
# Schema (all fields optional — only declared fields are checked/applied):
#
#   defaults:                        # applied to all repos unless overridden
#     description: ""                # repo description (empty = clear it)
#     homepage: ""                   # repo homepage URL
#     has_issues: true
#     has_projects: false
#     has_wiki: false
#     has_discussions: false
#     allow_squash_merge: true
#     allow_merge_commit: false
#     allow_rebase_merge: false
#     allow_auto_merge: true
#     delete_branch_on_merge: true
#     squash_merge_commit_title: "PR_TITLE"   # PR_TITLE | COMMIT_OR_PR_TITLE
#     squash_merge_commit_message: "PR_BODY"  # PR_BODY | COMMIT_MESSAGES | BLANK
#     topics: []                     # list of topic strings (replaces all topics)
#     vulnerability_alerts: true
#
#   overrides:                       # per-repo overrides (merged over defaults)
#     my-special-repo:
#       has_wiki: true
#       topics:
#         - special-topic
#
#   skip:                            # repos to skip entirely
#     - some-archived-repo
#
# ── Required env vars ─────────────────────────────────────────────────────────
#
#   GH_TOKEN       — PAT with repo + read:org scopes
#   GITHUB_OWNER   — org/user owning the repos
#
# ── Optional env vars ─────────────────────────────────────────────────────────
#
#   MODE           — "check" (default) or "apply"
#   SETTINGS_FILE  — path to settings YAML (default: config/repo-settings.yml)
#   REPO_FILTER    — substring filter on repo name (blank = all OSP-bound repos)
#   REPOS          — explicit space-separated repo list (overrides REPO_FILTER)
#   DRY_RUN        — alias for MODE=check (if "true", forces check mode)
#   BUDGET_MINUTES — max runtime in minutes (default: 45)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_OWNER:?GITHUB_OWNER is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/includes/budget.sh"
source "${SCRIPT_DIR}/includes/gh-api.sh"
budget_init

MODE="${MODE:-check}"
[[ "${DRY_RUN:-false}" == "true" ]] && MODE="check"
SETTINGS_FILE="${SETTINGS_FILE:-config/repo-settings.yml}"
REPO_FILTER="${REPO_FILTER:-}"
REPOS="${REPOS:-}"
BUDGET_MINUTES="${BUDGET_MINUTES:-45}"
GH_API="https://api.github.com"

info() { echo "[manage-repo-settings] $*" >&2; }
warn() { echo "[manage-repo-settings][warn] $*" >&2; }
ok()   { echo "[manage-repo-settings] ✅ $*" >&2; }
fail() { echo "[manage-repo-settings] ❌ $*" >&2; exit 1; }

# ── Validate settings file ────────────────────────────────────────────────────

[[ -f "$SETTINGS_FILE" ]] || fail "Settings file not found: ${SETTINGS_FILE}"

python3 -c "
import yaml, sys
try:
    data = yaml.safe_load(open('${SETTINGS_FILE}'))
    assert isinstance(data, dict), 'root must be a mapping'
    print('settings file OK')
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" >&2 || fail "Invalid settings file: ${SETTINGS_FILE}"

# ── Build repo list ───────────────────────────────────────────────────────────

if [[ -n "$REPOS" ]]; then
  repo_list="$REPOS"
else
  # Default: all OSP-bound repos from gitlab-subgroups.yml
  repo_list=$(python3 -c "
import yaml
data = yaml.safe_load(open('config/gitlab-subgroups.yml'))
for sg in data.get('subgroups', {}).values():
    for repo in (sg.get('repos') or []):
        print(repo)
" 2>/dev/null)
  if [[ -n "$REPO_FILTER" ]]; then
    repo_list=$(echo "$repo_list" | grep -i "$REPO_FILTER" || true)
  fi
fi

total=$(echo "$repo_list" | grep -c '.' || echo 0)
info "Mode: ${MODE} | Repos: ${total} | Settings: ${SETTINGS_FILE}"
echo "" >&2

# ── Load settings into env for Python ────────────────────────────────────────

settings_json=$(python3 -c "
import yaml, json, sys
data = yaml.safe_load(open('${SETTINGS_FILE}'))
print(json.dumps(data))
" 2>/dev/null) || fail "Could not parse ${SETTINGS_FILE}"

# ── Per-repo processing ───────────────────────────────────────────────────────

checked=0; drifted=0; applied=0; skipped=0; errors=0

while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue
  budget_check "$BUDGET_MINUTES" || { warn "Budget exhausted — stopping."; break; }

  # Check skip list
  is_skipped=$(python3 -c "
import json, sys
data = json.loads('''${settings_json}''')
skip = data.get('skip', []) or []
print('true' if '${repo}' in skip else 'false')
" 2>/dev/null)
  if [[ "$is_skipped" == "true" ]]; then
    info "  SKIP ${repo} (in skip list)"
    (( skipped++ )) || true
    continue
  fi

  # Fetch current repo state (1 REST call)
  current=$(gh_get "${GH_API}/repos/${GITHUB_OWNER}/${repo}" 2>/dev/null) || {
    warn "  ${repo}: could not fetch current state — skipping"
    (( errors++ )) || true
    continue
  }

  # Compute desired state and drift
  drift_result=$(python3 -c "
import json, sys

settings = json.loads('''${settings_json}''')
current  = json.loads(sys.stdin.read())
repo     = '${repo}'

defaults  = settings.get('defaults', {}) or {}
overrides = (settings.get('overrides', {}) or {}).get(repo, {}) or {}
desired   = {**defaults, **overrides}

# Fields that map directly to PATCH /repos/{owner}/{repo}
PATCH_FIELDS = {
    'description', 'homepage', 'has_issues', 'has_projects', 'has_wiki',
    'has_discussions', 'allow_squash_merge', 'allow_merge_commit',
    'allow_rebase_merge', 'allow_auto_merge', 'delete_branch_on_merge',
    'squash_merge_commit_title', 'squash_merge_commit_message',
}

drift = {}
patch = {}

for field, want in desired.items():
    if field in ('topics', 'vulnerability_alerts', 'skip'):
        continue
    if field not in PATCH_FIELDS:
        continue
    got = current.get(field)
    if got != want:
        drift[field] = {'current': got, 'desired': want}
        patch[field] = want

# Topics drift (separate API call needed)
if 'topics' in desired:
    want_topics = sorted(desired['topics'] or [])
    got_topics  = sorted(current.get('topics', []) or [])
    if want_topics != got_topics:
        drift['topics'] = {'current': got_topics, 'desired': want_topics}

result = {'drift': drift, 'patch': patch, 'desired': desired}
print(json.dumps(result))
" <<< "$current" 2>/dev/null) || {
    warn "  ${repo}: drift computation failed"
    (( errors++ )) || true
    continue
  }

  drift_count=$(python3 -c "
import json, sys
d = json.loads('''${drift_result}''')
print(len(d.get('drift', {})))
" 2>/dev/null || echo 0)

  (( checked++ )) || true

  if [[ "$drift_count" -eq 0 ]]; then
    info "  ${repo}: ✅ no drift"
    continue
  fi

  (( drifted++ )) || true

  # Report drift
  python3 -c "
import json, sys
d = json.loads('''${drift_result}''')
for field, diff in d.get('drift', {}).items():
    print(f'  ${repo}: DRIFT {field}: {diff[\"current\"]!r} → {diff[\"desired\"]!r}', file=sys.stderr)
" >&2

  if [[ "$MODE" == "check" ]]; then
    continue
  fi

  # ── Apply mode ──────────────────────────────────────────────────────────────

  # PATCH repo settings
  patch_body=$(python3 -c "
import json, sys
d = json.loads('''${drift_result}''')
patch = d.get('patch', {})
if patch:
    print(json.dumps(patch))
else:
    print('')
" 2>/dev/null)

  if [[ -n "$patch_body" ]]; then
    http=$(curl -sf -o /dev/null -w "%{http_code}" \
      -X PATCH \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      "${GH_API}/repos/${GITHUB_OWNER}/${repo}" \
      -d "$patch_body" 2>/dev/null) || http="000"
    if [[ "$http" =~ ^2 ]]; then
      info "  ${repo}: PATCH applied (HTTP ${http})"
    else
      warn "  ${repo}: PATCH failed (HTTP ${http})"
      (( errors++ )) || true
    fi
  fi

  # PUT topics (separate endpoint)
  topics_desired=$(python3 -c "
import json, sys
d = json.loads('''${drift_result}''')
if 'topics' in d.get('drift', {}):
    print(json.dumps({'names': d['drift']['topics']['desired']}))
else:
    print('')
" 2>/dev/null)

  if [[ -n "$topics_desired" ]]; then
    http=$(curl -sf -o /dev/null -w "%{http_code}" \
      -X PUT \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github.mercy-preview+json" \
      -H "Content-Type: application/json" \
      "${GH_API}/repos/${GITHUB_OWNER}/${repo}/topics" \
      -d "$topics_desired" 2>/dev/null) || http="000"
    if [[ "$http" =~ ^2 ]]; then
      info "  ${repo}: topics applied (HTTP ${http})"
    else
      warn "  ${repo}: topics PATCH failed (HTTP ${http})"
      (( errors++ )) || true
    fi
  fi

  # PUT vulnerability alerts
  vuln_desired=$(python3 -c "
import json, sys
d = json.loads('''${drift_result}''')
desired = d.get('desired', {})
if 'vulnerability_alerts' in desired:
    print('true' if desired['vulnerability_alerts'] else 'false')
else:
    print('')
" 2>/dev/null)

  if [[ -n "$vuln_desired" ]]; then
    vuln_method="PUT"
    [[ "$vuln_desired" == "false" ]] && vuln_method="DELETE"
    http=$(curl -sf -o /dev/null -w "%{http_code}" \
      -X "$vuln_method" \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github.dorian-preview+json" \
      "${GH_API}/repos/${GITHUB_OWNER}/${repo}/vulnerability-alerts" \
      2>/dev/null) || http="000"
    if [[ "$http" =~ ^2 ]]; then
      info "  ${repo}: vulnerability_alerts=${vuln_desired} applied (HTTP ${http})"
    else
      warn "  ${repo}: vulnerability_alerts failed (HTTP ${http})"
      (( errors++ )) || true
    fi
  fi

  (( applied++ )) || true
  ok "${repo}: settings applied"

done <<< "$repo_list"

# ── Summary ───────────────────────────────────────────────────────────────────

echo "" >&2
info "── Results ──────────────────────────────────────────────────────────────"
info "  Checked : ${checked}"
info "  Drifted : ${drifted}"
info "  Applied : ${applied}"
info "  Skipped : ${skipped}"
info "  Errors  : ${errors}"
info "  Mode    : ${MODE}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >> "$GITHUB_STEP_SUMMARY" << SUMMARY_EOF
## Repo Settings — ${MODE^}

| Metric | Count |
|---|---|
| Checked | ${checked} |
| Drifted | ${drifted} |
| Applied | ${applied} |
| Skipped | ${skipped} |
| Errors  | ${errors} |

**Mode:** \`${MODE}\` | **Settings file:** \`${SETTINGS_FILE}\`
SUMMARY_EOF
fi

[[ "$errors" -gt 0 ]] && exit 1
exit 0
