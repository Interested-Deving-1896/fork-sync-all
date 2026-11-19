#!/usr/bin/env bash
# POST /api/fsa/workflows/:name/run
# Dispatches a workflow (GitHub Actions), triggers a pipeline (GitLab CI),
# or runs an Action (Gitea/Forgejo) on the active platform.
#
# Path param:  :name  — workflow filename / job name / pipeline ref
# Body (JSON): { "inputs": { "key": "value" }, "ref": "main", "platform": "github" }
#
# Returns: { "ok": true, "run_url": "...", "workflow": "..." }
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

WORKFLOW_NAME="${PATH_name:-}"
REF="${BODY_ref:-main}"
PLATFORM_OVERRIDE="${BODY_platform:-${QUERY_platform:-}}"

if [[ -z "$WORKFLOW_NAME" ]]; then
  fsa_error "workflow name is required" 400
  exit 0
fi

# Re-init platform if override requested
if [[ -n "$PLATFORM_OVERRIDE" ]]; then
  fsa_platform_init "$PLATFORM_OVERRIDE"
fi

ACTIVE_PLATFORM="${PA_PLATFORM:-github}"

# ── GitLab: trigger pipeline ──────────────────────────────────────────────────
if [[ "$ACTIVE_PLATFORM" == "gitlab" ]]; then
  gitlab_host="${PA_HOST:-https://gitlab.com}"
  gitlab_token="${GITLAB_TOKEN:-}"
  group_path="${FSA_GITLAB_GROUP:-openos-project/ops}"
  repo="${FSA_REPO##*/}"
  inputs_json="${BODY_inputs:-{}}"
  python3 - << GLEOF
import json, urllib.request, urllib.error, sys

gl_host    = '${gitlab_host}'
token      = '${gitlab_token}'
group      = '${group_path}'
repo       = '${repo}'
ref        = '${REF}'
inputs_raw = '${inputs_json}'

try:
    inputs = json.loads(inputs_raw) if inputs_raw else {}
except Exception:
    inputs = {}

encoded = group.replace('/', '%2F')
# Resolve project ID
try:
    req = urllib.request.Request(
        f"{gl_host}/api/v4/projects/{encoded}%2F{repo}",
        headers={'PRIVATE-TOKEN': token})
    with urllib.request.urlopen(req, timeout=10) as r:
        proj = json.loads(r.read())
    project_id = proj['id']
except Exception as e:
    print(json.dumps({'ok': False, 'error': f'project not found: {e}', 'code': 404}))
    sys.exit(0)

# Trigger pipeline
body = json.dumps({
    'ref': ref,
    'variables': [{'key': k, 'value': str(v)} for k, v in inputs.items()]
}).encode()
req = urllib.request.Request(
    f"{gl_host}/api/v4/projects/{project_id}/pipeline",
    data=body,
    headers={'PRIVATE-TOKEN': token, 'Content-Type': 'application/json'},
    method='POST')
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        resp = json.loads(r.read())
    print(json.dumps({'ok': True, 'platform': 'gitlab',
                      'pipeline_id': resp.get('id'),
                      'pipeline_url': resp.get('web_url', ''),
                      'ref': ref}))
except urllib.error.HTTPError as e:
    err = e.read().decode()
    print(json.dumps({'ok': False, 'error': err, 'code': e.code}))
GLEOF
  exit 0
fi

# ── Gitea / Forgejo: dispatch workflow ────────────────────────────────────────
if [[ "$ACTIVE_PLATFORM" == "gitea" || "$ACTIVE_PLATFORM" == "forgejo" ]]; then
  gitea_host="${PA_HOST:-}"
  gitea_token="${GITEA_TOKEN:-${FORGEJO_TOKEN:-}}"
  gitea_org="${FSA_ORG:-}"
  gitea_repo="${FSA_REPO##*/}"
  inputs_json="${BODY_inputs:-{}}"
  wf_file="${WORKFLOW_NAME}"
  [[ "$wf_file" != *.yml && "$wf_file" != *.yaml ]] && wf_file="${wf_file}.yml"
  python3 - << GTEOF
import json, urllib.request, urllib.error, sys

host       = '${gitea_host}'
token      = '${gitea_token}'
org        = '${gitea_org}'
repo       = '${gitea_repo}'
wf_file    = '${wf_file}'
ref        = '${REF}'
inputs_raw = '${inputs_json}'

try:
    inputs = json.loads(inputs_raw) if inputs_raw else {}
except Exception:
    inputs = {}

body = json.dumps({'ref': ref, 'inputs': inputs}).encode()
req = urllib.request.Request(
    f"{host}/api/v1/repos/{org}/{repo}/actions/workflows/{wf_file}/dispatches",
    data=body,
    headers={'Authorization': f'token {token}', 'Content-Type': 'application/json'},
    method='POST')
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        print(json.dumps({'ok': True, 'platform': '${ACTIVE_PLATFORM}',
                          'workflow': wf_file, 'ref': ref}))
except urllib.error.HTTPError as e:
    print(json.dumps({'ok': False, 'error': e.read().decode(), 'code': e.code}))
GTEOF
  exit 0
fi

# ── Codeberg: Forgejo-compatible dispatch ─────────────────────────────────────
if [[ "$ACTIVE_PLATFORM" == "codeberg" ]]; then
  GITEA_TOKEN="${CODEBERG_TOKEN:-}" \
  PA_HOST="https://codeberg.org" \
  ACTIVE_PLATFORM="forgejo" \
  exec "$0" "$@"
fi

# ── GitHub (default): existing implementation ─────────────────────────────────

# Resolve filename if display name was given
resolve_workflow_file() {
  local name="$1"
  local workflows_dir="${_FSA_ROOT}/.github/workflows"
  # Exact filename match
  [[ -f "${workflows_dir}/${name}" ]] && echo "$name" && return
  [[ -f "${workflows_dir}/${name}.yml" ]] && echo "${name}.yml" && return
  # Match by display name
  for f in "${workflows_dir}"/*.yml "${workflows_dir}"/*.yaml; do
    [[ -f "$f" ]] || continue
    wname=$(python3 -c "import yaml; d=yaml.safe_load(open('$f')); print(d.get('name',''))" 2>/dev/null || echo "")
    if [[ "$wname" == "$name" ]]; then
      echo "$(basename "$f")"
      return
    fi
  done
  echo ""
}

workflow_file=$(resolve_workflow_file "$WORKFLOW_NAME")
if [[ -z "$workflow_file" ]]; then
  fsa_error "workflow not found: ${WORKFLOW_NAME}" 404
  exit 0
fi

# Check toggle
toggle_key="${workflow_file}"
if ! fsa_toggle_enabled "$toggle_key" 2>/dev/null; then
  fsa_error "workflow is disabled by toggle: ${workflow_file}" 403
  exit 0
fi

fsa_quota_check 50 || exit 0

# Parse inputs from request body
inputs_json="${BODY_inputs:-{}}"

# Dispatch
result=$(fsa_api_post \
  "/repos/${FSA_REPO}/actions/workflows/${workflow_file}/dispatches" \
  "{\"ref\":\"${REF}\",\"inputs\":${inputs_json}}")

# GitHub returns 204 No Content on success — empty body = success
if [[ -z "$result" ]] || echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if not d.get('message') else 1)" 2>/dev/null; then
  # Get the run URL (latest run for this workflow)
  sleep 2
  runs=$(fsa_api_get "/repos/${FSA_REPO}/actions/workflows/${workflow_file}/runs?per_page=1")
  run_url=$(echo "$runs" | python3 -c "
import json,sys
d=json.load(sys.stdin)
runs=d.get('workflow_runs',[])
print(runs[0].get('html_url','') if runs else '')
" 2>/dev/null || echo "")
  echo "{\"ok\":true,\"workflow\":\"${workflow_file}\",\"ref\":\"${REF}\",\"run_url\":\"${run_url}\"}"
else
  msg=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('message','dispatch failed'))" 2>/dev/null || echo "dispatch failed")
  fsa_error "$msg" 422
fi
