#!/usr/bin/env bash
#
# Checks the CI pipeline status of the default branch HEAD for every
# OSP-bound repo mirrored to gitlab.com/openos-project.
#
# For each repo, queries the GitLab Pipelines API for the latest pipeline
# on the default branch. A repo is considered failing if the latest pipeline
# status is failed, canceled, or blocked.
#
# Outputs a JSON array of failing repos to stdout:
#   [{"repo":"name","gl_path":"openos-project/sg/name","pipeline_id":123,
#     "status":"failed","url":"https://gitlab.com/...","web_url":"..."}, ...]
#
# Required env vars:
#   GITLAB_TOKEN   — GitLab PAT with read_api scope on openos-project
#
# Optional env vars:
#   REPO_FILTER    — substring filter on repo name (blank = all)
#   BUDGET_MINUTES — time budget in minutes (default: 55)
#   MIN_QUOTA      — skip if GitLab API calls remaining below this (default: 0,
#                    GitLab rate limit is 2000 req/min — not a concern here)
#   DRY_RUN        — if "true", report only without side effects

set -uo pipefail

: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"

REPO_FILTER="${REPO_FILTER:-}"
GL_API="https://gitlab.com/api/v4"
GL_AUTH="PRIVATE-TOKEN: ${GITLAB_TOKEN}"

# ── Logging ───────────────────────────────────────────────────────────────────
info() { echo "[check-gitlab-ci] $*" >&2; }
warn() { echo "[check-gitlab-ci] ⚠️  $*" >&2; }
ok()   { echo "[check-gitlab-ci] ✓ $*" >&2; }

# ── Budget guard ──────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/includes/budget.sh"
budget_init

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG="${REPO_ROOT}/config/gitlab-subgroups.yml"

if [[ ! -f "$CONFIG" ]]; then
  warn "config/gitlab-subgroups.yml not found"
  echo "[]"
  exit 1
fi

# ── GitLab API helper ─────────────────────────────────────────────────────────
gl_get() {
  curl -sf -H "$GL_AUTH" "$@" 2>/dev/null
}

# ── Build repo→gl_path map from config ───────────────────────────────────────
# Returns lines of: repo_name<TAB>gl_path<TAB>default_branch
mapfile -t REPO_ENTRIES < <(python3 - "$CONFIG" <<'PYEOF'
import yaml, sys

config_path = sys.argv[1]
data = yaml.safe_load(open(config_path))
subgroups = data.get("subgroups", {}) or {}
default_sg = data.get("default_subgroup", "ops")

for sg_name, sg in subgroups.items():
    sg_path = sg.get("path") or f"openos-project/{sg_name}"
    for repo in (sg.get("repos") or []):
        gl_path = f"{sg_path}/{repo}"
        print(f"{repo}\t{gl_path}")
PYEOF
)

info "OSP-bound repos to check: ${#REPO_ENTRIES[@]}"

# ── Check pipeline status for each repo ──────────────────────────────────────
failing_repos="[]"
checked=0
skipped=0
no_pipeline=0

for entry in "${REPO_ENTRIES[@]}"; do
  repo=$(echo "$entry" | cut -f1)
  gl_path=$(echo "$entry" | cut -f2)

  budget_check "$repo" || break

  if [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]]; then
    continue
  fi

  # URL-encode the full path (/ → %2F)
  encoded_path=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],''))" "$gl_path")

  # Get latest pipeline on default branch
  # GitLab returns pipelines sorted by id desc — first result is the latest
  pipeline_json=$(gl_get "${GL_API}/projects/${encoded_path}/pipelines?per_page=1&order_by=id&sort=desc" || echo "[]")

  if [[ "$pipeline_json" == "[]" || "$pipeline_json" == "" ]]; then
    info "${gl_path}: no pipelines found — skipping"
    (( no_pipeline++ ))
    continue
  fi

  (( checked++ ))

  status=$(echo "$pipeline_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not d: print('none'); sys.exit(0)
print(d[0].get('status','unknown'))
" 2>/dev/null || echo "unknown")

  pipeline_id=$(echo "$pipeline_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not d: print(0); sys.exit(0)
print(d[0].get('id',0))
" 2>/dev/null || echo "0")

  web_url=$(echo "$pipeline_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not d: print(''); sys.exit(0)
print(d[0].get('web_url',''))
" 2>/dev/null || echo "")

  ref=$(echo "$pipeline_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not d: print(''); sys.exit(0)
print(d[0].get('ref',''))
" 2>/dev/null || echo "")

  sha=$(echo "$pipeline_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not d: print(''); sys.exit(0)
print(d[0].get('sha','')[:7])
" 2>/dev/null || echo "")

  # failed / canceled / blocked are actionable failures
  # running / pending / created / waiting_for_resource / preparing / scheduled are in-progress
  # success / skipped / manual are healthy
  case "$status" in
    failed|canceled|blocked)
      warn "${gl_path}: pipeline #${pipeline_id} ${status} on ${ref}@${sha} — ${web_url}"
      failing_repos=$(echo "$failing_repos" | python3 -c "
import json,sys
lst = json.load(sys.stdin)
lst.append({
  'repo':        '${repo}',
  'gl_path':     '${gl_path}',
  'pipeline_id': ${pipeline_id},
  'status':      '${status}',
  'ref':         '${ref}',
  'sha':         '${sha}',
  'web_url':     '${web_url}'
})
print(json.dumps(lst))
" 2>/dev/null || echo "$failing_repos")
      ;;
    success|skipped|manual)
      ok "${gl_path}: pipeline #${pipeline_id} ${status} on ${ref}@${sha}"
      ;;
    running|pending|created|waiting_for_resource|preparing|scheduled)
      info "${gl_path}: pipeline #${pipeline_id} ${status} (in progress) — not counted as failure"
      ;;
    *)
      warn "${gl_path}: pipeline #${pipeline_id} unknown status '${status}'"
      ;;
  esac
done

failing_count=$(echo "$failing_repos" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")
info "Checked: ${checked} | Failing: ${failing_count} | No pipeline: ${no_pipeline} | Skipped: ${skipped}"

echo "$failing_repos"
