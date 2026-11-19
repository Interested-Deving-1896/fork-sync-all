#!/usr/bin/env bash
#
# scripts/resolve-ci.sh — agnostic CI failure resolver
#
# Platform-agnostic counterpart to check-ci.sh. Resolves CI failures across
# any target registered in config/ci-check-targets.yml.
#
# For GitHub targets: delegates to resolve-failures.sh (LLM analysis + auto-fix
# + rate-limit rerun). Scopes the scan to the org registered in the target.
#
# For GitLab targets: retries failed/canceled pipelines on the default branch.
# No LLM analysis for GitLab — pipeline retries are the primary recovery action.
#
# Outputs a JSON summary to stdout:
#   {
#     "target_id": "osp-github",
#     "platform": "github",
#     "scanned": 42,
#     "failures_found": 3,
#     "fixed": 2,
#     "retried": 1,
#     "unfixable": 0
#   }
#
# Required env vars:
#   PLATFORM       — github | gitlab
#   TARGET_ORG     — org/group name on the platform
#   TOKEN          — API token
#   TARGET_ID      — human-readable label (used in logs + output)
#
# Optional env vars:
#   SUBGROUPS_CONFIG — path to subgroups YAML for repo enumeration
#   REPO_FILTER    — optional substring filter on repo name
#   API_URL        — base API URL (default: platform canonical URL)
#   BUDGET_MINUTES — time budget (default: 110)
#   MIN_QUOTA      — skip if GitHub quota below this (default: 100)
#   DRY_RUN        — "true" = report without applying fixes
#   WATCHDOG_REPO  — repo to close ci-watchdog issues in (GitHub only)
#   GH_TOKEN       — alias for TOKEN when PLATFORM=github

set -uo pipefail

PLATFORM="${PLATFORM:?PLATFORM is required (github|gitlab)}"
TARGET_ORG="${TARGET_ORG:?TARGET_ORG is required}"
TOKEN="${TOKEN:-${GH_TOKEN:-}}"
: "${TOKEN:?TOKEN (or GH_TOKEN) is required}"

TARGET_ID="${TARGET_ID:-${PLATFORM}/${TARGET_ORG}}"
REPO_FILTER="${REPO_FILTER:-}"
BUDGET_MINUTES="${BUDGET_MINUTES:-110}"
MIN_QUOTA="${MIN_QUOTA:-100}"
DRY_RUN="${DRY_RUN:-false}"
WATCHDOG_REPO="${WATCHDOG_REPO:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Logging ───────────────────────────────────────────────────────────────────
info() { echo "[resolve-ci:${TARGET_ID}] $*" >&2; }
warn() { echo "[resolve-ci:${TARGET_ID}] ⚠  $*" >&2; }
ok()   { echo "[resolve-ci:${TARGET_ID}] ✓ $*" >&2; }

# ── Platform dispatch ─────────────────────────────────────────────────────────

_resolve_github() {
  local owner="$1"

  # Derive OSP-bound repo list from subgroups config for scoping the scan.
  # Without this, resolve-failures.sh would paginate the entire org (4000+ repos
  # for Interested-Deving-1896), exhausting quota and timing out.
  local repos_override=""
  local config="${SUBGROUPS_CONFIG:-${REPO_ROOT}/config/gitlab-subgroups.yml}"
  if [[ -f "$config" ]]; then
    repos_override=$(python3 -c "
import yaml, sys
data = yaml.safe_load(open('${config}'))
repos = []
for sg in (data.get('subgroups') or {}).values():
    repos.extend(sg.get('repos') or [])
print(' '.join(sorted(set(repos))))
" 2>/dev/null || echo "")
  fi

  info "Delegating to resolve-failures.sh (owner=${owner}, repos=$(echo "$repos_override" | wc -w | tr -d ' '))"

  local watchdog_arg="${WATCHDOG_REPO:-${REPO_ROOT##*/}}"
  local json_tmp
  json_tmp=$(mktemp /tmp/resolve-failures-summary-XXXXXX.json)

  GH_TOKEN="$TOKEN" \
  SCAN_OWNERS="$owner" \
  REPO_FILTER="$REPO_FILTER" \
  DRY_RUN="$DRY_RUN" \
  BUDGET_MINUTES="$BUDGET_MINUTES" \
  WATCHDOG_REPO="$watchdog_arg" \
  OSP_REPOS_OVERRIDE="$repos_override" \
  JSON_OUT="$json_tmp" \
    bash "${SCRIPT_DIR}/resolve-failures.sh"
  local rc=$?

  # Emit unified JSON summary to stdout
  if [[ -s "$json_tmp" ]]; then
    python3 -c "
import json
inner = json.load(open('${json_tmp}'))
print(json.dumps({
  'target_id':     '${TARGET_ID}',
  'platform':      'github',
  'org':           '${owner}',
  'scanned':       inner.get('scanned', 0),
  'failures_found': inner.get('failures_found', 0),
  'fixed':         inner.get('fixed', 0),
  'retried':       inner.get('rl_rerun', 0),
  'unfixable':     inner.get('unfixable', 0),
}))
"
  else
    python3 -c "import json; print(json.dumps({'target_id':'${TARGET_ID}','platform':'github','org':'${owner}','scanned':0,'failures_found':0,'fixed':0,'retried':0,'unfixable':0,'note':'no_summary_written'}))"
  fi
  rm -f "$json_tmp"
  return $rc
}

_resolve_gitlab() {
  local group="$1"
  local api_url="${API_URL:-https://gitlab.com}"

  info "Scanning GitLab group ${group} for failed/canceled pipelines…"

  source "${SCRIPT_DIR}/includes/budget.sh"
  budget_init

  # Load repo list from subgroups config
  local config="${SUBGROUPS_CONFIG:-${REPO_ROOT}/config/gitlab-subgroups.yml}"
  local repos=()
  if [[ -f "$config" ]]; then
    mapfile -t repos < <(python3 -c "
import yaml
data = yaml.safe_load(open('${config}'))
repos = []
for sg in (data.get('subgroups') or {}).values():
    repos.extend(sg.get('repos') or [])
for r in sorted(set(repos)):
    print(r)
" 2>/dev/null)
  fi

  # Fall back to API enumeration if config is empty
  if [[ "${#repos[@]}" -eq 0 ]]; then
    info "No repos in config — enumerating ${group} via GitLab API…"
    local page=1
    while true; do
      local result
      result=$(curl -sf \
        -H "Authorization: Bearer ${TOKEN}" \
        "${api_url}/api/v4/groups/${group}/projects?per_page=100&page=${page}&include_subgroups=true" \
        2>/dev/null || echo "[]")
      local count
      count=$(echo "$result" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
      mapfile -t -O "${#repos[@]}" repos < <(echo "$result" | python3 -c "
import json,sys
for p in json.load(sys.stdin): print(p['path'])
" 2>/dev/null)
      (( count < 100 )) && break
      (( page++ ))
    done
  fi

  info "Repos to scan: ${#repos[@]}"

  local scanned=0 retried=0 unfixable=0

  for repo in "${repos[@]}"; do
    budget_check "$repo" || break
    [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]] && continue

    local group_path="${group}/${repo}"
    local encoded_path
    encoded_path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${group_path}', safe=''))")

    # Get default branch
    local project_json
    project_json=$(curl -sf \
      -H "Authorization: Bearer ${TOKEN}" \
      "${api_url}/api/v4/projects/${encoded_path}" \
      2>/dev/null || echo "{}")
    local default_branch
    default_branch=$(echo "$project_json" | python3 -c \
      "import json,sys; print(json.load(sys.stdin).get('default_branch','main'))" 2>/dev/null || echo "main")

    # Get latest pipeline on default branch
    local pipelines_json
    pipelines_json=$(curl -sf \
      -H "Authorization: Bearer ${TOKEN}" \
      "${api_url}/api/v4/projects/${encoded_path}/pipelines?ref=${default_branch}&per_page=1" \
      2>/dev/null || echo "[]")

    local pipeline_status pipeline_id
    pipeline_status=$(echo "$pipelines_json" | python3 -c \
      "import json,sys; d=json.load(sys.stdin); print(d[0].get('status','') if d else '')" \
      2>/dev/null || echo "")
    pipeline_id=$(echo "$pipelines_json" | python3 -c \
      "import json,sys; d=json.load(sys.stdin); print(d[0].get('id','') if d else '')" \
      2>/dev/null || echo "")

    (( scanned++ )) || true

    if [[ "$pipeline_status" =~ ^(failed|canceled)$ && -n "$pipeline_id" ]]; then
      warn "${group_path}: pipeline ${pipeline_status} (id=${pipeline_id}) — retrying"

      if [[ "$DRY_RUN" == "true" ]]; then
        info "[dry-run] would POST /projects/${encoded_path}/pipelines/${pipeline_id}/retry"
        (( retried++ )) || true
      else
        local http_code
        http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
          -X POST \
          -H "Authorization: Bearer ${TOKEN}" \
          "${api_url}/api/v4/projects/${encoded_path}/pipelines/${pipeline_id}/retry" \
          2>/dev/null || echo "000")

        if [[ "$http_code" == "201" ]]; then
          ok "${group_path}: pipeline retried (HTTP 201)"
          (( retried++ )) || true
        else
          warn "${group_path}: retry failed (HTTP ${http_code})"
          (( unfixable++ )) || true
        fi
      fi
    else
      ok "${group_path}: ${pipeline_status:-no_pipeline}"
    fi
  done

  info "Scanned: ${scanned} | Retried: ${retried} | Unfixable: ${unfixable}"
  budget_report

  # Emit JSON summary to stdout
  python3 -c "
import json
print(json.dumps({
  'target_id':     '${TARGET_ID}',
  'platform':      'gitlab',
  'org':           '${group}',
  'scanned':       ${scanned},
  'failures_found': $((retried + unfixable)),
  'fixed':         0,
  'retried':       ${retried},
  'unfixable':     ${unfixable},
}))
"
}

# ── Platform defaults ─────────────────────────────────────────────────────────
case "$PLATFORM" in
  github)
    API_URL="${API_URL:-https://api.github.com}"
    GH_TOKEN="$TOKEN"
    export GH_TOKEN
    SUBGROUPS_CONFIG="${SUBGROUPS_CONFIG:-${REPO_ROOT}/config/gitlab-subgroups.yml}"

    # Quota pre-flight
    _quota_json=$(curl -sf \
      -H "Authorization: token ${TOKEN}" \
      "${API_URL}/rate_limit" 2>/dev/null || echo '{}')
    _quota_remaining=$(echo "$_quota_json" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('resources',{}).get('core',{}).get('remaining',0))" \
      2>/dev/null || echo 0)
    _quota_reset=$(echo "$_quota_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
ts = d.get('resources',{}).get('core',{}).get('reset', 0)
if not ts:
    print('unknown')
else:
    import os
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath('${BASH_SOURCE[0]}')), 'includes'))
    try:
        from time_format import fmt_unix
        i = fmt_unix(ts)
        print(f\"{i['utc_24']} / {i['utc_12']}\")
    except Exception:
        from datetime import datetime, timezone
        print(datetime.utcfromtimestamp(ts).strftime('%H:%M UTC'))
" 2>/dev/null || echo 'unknown')

    if (( _quota_remaining < MIN_QUOTA )); then
      warn "Quota too low (${_quota_remaining} < ${MIN_QUOTA}) — resets at ${_quota_reset}. Skipping."
      python3 -c "import json; print(json.dumps({'target_id':'${TARGET_ID}','platform':'github','org':'${TARGET_ORG}','scanned':0,'failures_found':0,'fixed':0,'retried':0,'unfixable':0,'skipped':True,'reason':'quota_low'}))"
      exit 0
    fi
    info "Quota: ${_quota_remaining} remaining"

    _resolve_github "$TARGET_ORG"
    ;;

  gitlab)
    API_URL="${API_URL:-https://gitlab.com}"
    SUBGROUPS_CONFIG="${SUBGROUPS_CONFIG:-${REPO_ROOT}/config/gitlab-subgroups.yml}"
    _resolve_gitlab "$TARGET_ORG"
    ;;

  *)
    warn "Unsupported platform '${PLATFORM}'. Supported: github, gitlab"
    python3 -c "import json; print(json.dumps({'target_id':'${TARGET_ID}','platform':'${PLATFORM}','org':'${TARGET_ORG}','scanned':0,'failures_found':0,'fixed':0,'retried':0,'unfixable':0,'skipped':True,'reason':'unsupported_platform'}))"
    exit 1
    ;;
esac
