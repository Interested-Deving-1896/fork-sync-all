#!/usr/bin/env bash
# ona-projects.sh — Ona Projects operator layer
#
# Reads config/ona-projects.yml and syncs the declared projects to the Ona API.
# When ONA_TOKEN is absent the script runs in dry-run mode automatically.
#
# Usage:
#   bash scripts/ona-projects.sh [OPTIONS]
#
# Options:
#   --dry-run            Report what would change without calling the API
#   --register-osp       Auto-add OSP-bound repos from config/gitlab-subgroups.yml
#   --project <key>      Operate on a single project key only
#   --list               Print all known projects and exit
#   --get-env <key>      Print the environment URL for a project (creates if needed)
#   --help               Show this message
#
# Environment:
#   ONA_TOKEN            Ona API token (required for live calls; absent = dry-run)
#   ONA_API              Ona API base URL (default: https://app.ona.com/api/v1)
#   CONFIG               Path to ona-projects.yml (default: config/ona-projects.yml)

set -euo pipefail

info() { echo "[ona-projects] $*" >&2; }
warn() { echo "[ona-projects][warn] $*" >&2; }
dry()  { echo "[ona-projects][dry-run] $*" >&2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-${REPO_ROOT}/config/ona-projects.yml}"
ONA_API="${ONA_API:-https://app.ona.com/api/v1}"
DRY_RUN=false
REGISTER_OSP=false
FILTER_KEY=""
MODE="sync"

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=true ;;
    --register-osp)  REGISTER_OSP=true ;;
    --project)       FILTER_KEY="$2"; shift ;;
    --list)          MODE="list" ;;
    --get-env)       MODE="get-env"; FILTER_KEY="$2"; shift ;;
    --help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
      exit 0
      ;;
    *) warn "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# ── Token check ───────────────────────────────────────────────────────────────
if [[ -z "${ONA_TOKEN:-}" ]]; then
  warn "ONA_TOKEN not set — running in dry-run mode."
  warn "Add ONA_TOKEN to GitHub Actions secrets to enable live API calls."
  DRY_RUN=true
fi

# ── YAML helpers (Python) ─────────────────────────────────────────────────────
# All YAML parsing goes through Python to avoid hand-rolled parsers (AGENTS.md).

_py() { python3 -c "$1" 2>/dev/null; }

ona_org() {
  _py "import yaml; d=yaml.safe_load(open('${CONFIG}')); print(d.get('ona_org',''))"
}

runner() {
  _py "import yaml; d=yaml.safe_load(open('${CONFIG}')); print(d.get('runner',''))"
}

default_class() {
  _py "import yaml; d=yaml.safe_load(open('${CONFIG}')); print(d.get('default_class','Regular'))"
}

list_project_keys() {
  _py "
import yaml
d = yaml.safe_load(open('${CONFIG}'))
for k in (d.get('projects') or {}).keys():
    print(k)
"
}

project_field() {
  local key="$1" field="$2"
  _py "
import yaml
d = yaml.safe_load(open('${CONFIG}'))
p = (d.get('projects') or {}).get('${key}', {})
print(p.get('${field}', ''))
"
}

project_classes() {
  local key="$1"
  _py "
import yaml
d = yaml.safe_load(open('${CONFIG}'))
p = (d.get('projects') or {}).get('${key}', {})
classes = p.get('classes') or [d.get('default_class','Regular')]
print(' '.join(classes))
"
}

# ── Ona API calls ─────────────────────────────────────────────────────────────

ona_get() {
  local path="$1"
  if [[ "$DRY_RUN" == "true" ]]; then
    dry "GET ${ONA_API}${path}"
    echo "{}"
    return 0
  fi
  curl -sf \
    -H "Authorization: Bearer ${ONA_TOKEN}" \
    -H "Content-Type: application/json" \
    "${ONA_API}${path}" || echo "{}"
}

ona_post() {
  local path="$1" body="$2"
  if [[ "$DRY_RUN" == "true" ]]; then
    dry "POST ${ONA_API}${path}"
    dry "  body: ${body}"
    echo "{}"
    return 0
  fi
  curl -sf -X POST \
    -H "Authorization: Bearer ${ONA_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "${ONA_API}${path}" || echo "{}"
}

ona_patch() {
  local path="$1" body="$2"
  if [[ "$DRY_RUN" == "true" ]]; then
    dry "PATCH ${ONA_API}${path}"
    dry "  body: ${body}"
    echo "{}"
    return 0
  fi
  curl -sf -X PATCH \
    -H "Authorization: Bearer ${ONA_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "${ONA_API}${path}" || echo "{}"
}

# ── Project sync ──────────────────────────────────────────────────────────────

sync_project() {
  local key="$1"
  local repo name project_id branch description
  repo=$(project_field "$key" "repo")
  name=$(project_field "$key" "name")
  project_id=$(project_field "$key" "project_id")
  branch=$(project_field "$key" "branch")
  description=$(project_field "$key" "description")
  branch="${branch:-main}"

  if [[ -z "$repo" ]]; then
    warn "Project '${key}' has no repo — skipping."
    return 0
  fi

  info "Syncing project: ${key} (${name:-$key})"

  local classes
  classes=$(project_classes "$key")

  local body
  body=$(python3 -c "
import json
print(json.dumps({
  'name': '${name:-$key}',
  'cloneUrl': '${repo}',
  'branch': '${branch}',
  'description': '''${description}'''.strip(),
  'environmentClasses': '${classes}'.split(),
}))
")

  if [[ -z "$project_id" ]]; then
    info "  Creating new project..."
    local result
    result=$(ona_post "/projects" "$body")
    local new_id
    new_id=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
    if [[ -n "$new_id" && "$DRY_RUN" == "false" ]]; then
      info "  Created: ${new_id}"
      # Write project_id back to config
      python3 - <<PYEOF
import yaml, re
with open('${CONFIG}') as f:
    content = f.read()
# Replace the project_id line for this key
# Find the block and update project_id: ""
import re
pattern = r'(  ${key}:.*?project_id:)\s*""'
replacement = r'\1 "${new_id}"'
content = re.sub(pattern, replacement, content, flags=re.DOTALL)
with open('${CONFIG}', 'w') as f:
    f.write(content)
PYEOF
    fi
  else
    info "  Updating existing project: ${project_id}"
    ona_patch "/projects/${project_id}" "$body" > /dev/null
  fi
}

# ── Register OSP repos ────────────────────────────────────────────────────────

register_osp_repos() {
  local subgroups_config="${REPO_ROOT}/config/gitlab-subgroups.yml"
  info "Registering OSP-bound repos from ${subgroups_config}..."

  python3 - <<PYEOF
import yaml, re, sys

with open('${subgroups_config}') as f:
    sg_data = yaml.safe_load(f)

with open('${CONFIG}') as f:
    proj_data = yaml.safe_load(f)

existing = set((proj_data.get('projects') or {}).keys())
subgroups = sg_data.get('subgroups', {}) or {}

new_entries = []
for slug, sg in subgroups.items():
    for repo in (sg.get('repos') or []):
        key = repo.replace('-', '-').replace('_', '-').lower()
        if key in existing:
            continue
        entry = f"""
  {key}:
    repo: https://github.com/OpenOS-Project-OSP/{repo}
    name: "{repo}"
    project_id: ""
    branch: main
    classes: [Regular]
    description: "OSP-bound repo — {repo}"
    tags: [osp-bound]"""
        new_entries.append(entry)
        existing.add(key)

if not new_entries:
    print('[ona-projects] No new OSP repos to register.', file=sys.stderr)
    sys.exit(0)

with open('${CONFIG}') as f:
    content = f.read()

# Append before the end of file
content = content.rstrip('\n') + '\n' + '\n'.join(new_entries) + '\n'
with open('${CONFIG}', 'w') as f:
    f.write(content)

print(f'[ona-projects] Registered {len(new_entries)} new OSP repos.', file=sys.stderr)
PYEOF
}

# ── Get / create environment ──────────────────────────────────────────────────

get_or_create_env() {
  local key="$1"
  local project_id
  project_id=$(project_field "$key" "project_id")

  if [[ -z "$project_id" ]]; then
    warn "Project '${key}' has no project_id — run sync first."
    exit 1
  fi

  info "Getting environment for project: ${key} (${project_id})"
  local result
  result=$(ona_post "/environments" "{\"projectId\": \"${project_id}\"}")
  local url
  url=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('url', d.get('id','')))" 2>/dev/null || echo "")
  echo "$url"
}

# ── List mode ─────────────────────────────────────────────────────────────────

list_projects() {
  python3 - <<PYEOF
import yaml, sys
with open('${CONFIG}') as f:
    d = yaml.safe_load(f)
projects = d.get('projects') or {}
print(f"{'KEY':<30} {'NAME':<35} {'PROJECT_ID':<30} TAGS")
print('-' * 110)
for key, p in projects.items():
    tags = ', '.join(p.get('tags') or [])
    pid  = p.get('project_id') or '(not synced)'
    name = p.get('name') or key
    print(f"{key:<30} {name:<35} {pid:<30} {tags}")
PYEOF
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  case "$MODE" in
    list)
      list_projects
      ;;
    get-env)
      [[ -z "$FILTER_KEY" ]] && { warn "--get-env requires a project key"; exit 1; }
      get_or_create_env "$FILTER_KEY"
      ;;
    sync)
      [[ "$REGISTER_OSP" == "true" ]] && register_osp_repos

      local keys
      if [[ -n "$FILTER_KEY" ]]; then
        keys="$FILTER_KEY"
      else
        keys=$(list_project_keys)
      fi

      local synced=0 skipped=0
      while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        sync_project "$key" && (( synced++ )) || (( skipped++ )) || true
      done <<< "$keys"

      info "Done. synced=${synced} skipped=${skipped} dry_run=${DRY_RUN}"
      ;;
  esac
}

main
