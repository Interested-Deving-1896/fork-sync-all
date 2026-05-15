#!/usr/bin/env bash
#
# Export or import a manifest of git repositories.
#
# Inspired by svandragt/repoman — extended to support multiple platforms,
# GitHub org scanning, and manifest-driven bulk import into a target org.
#
# Modes
# ─────
#   export  — scan a GitHub org (or a local directory) and write a manifest
#             file listing each repo's name and clone URL
#   import  — read a manifest file and clone/push each repo into a target org
#
# Manifest format (one repo per line):
#   <name> <clone_url>
#   # lines starting with # are comments
#
# Required env vars:
#   GH_TOKEN  — GitHub PAT (repo + admin:org scopes)
#   MODE      — export | import
#
# Export env vars:
#   EXPORT_ORG      — GitHub org to scan
#   EXPORT_FILE     — output manifest file path (default: repos.manifest)
#   EXPORT_PLATFORM — github | gitlab | bitbucket | gitea (default: github)
#   SOURCE_TOKEN    — PAT for source platform (if different from GH_TOKEN)
#   SOURCE_BASE_URL — base URL for self-hosted instances
#   INCLUDE_FILTER  — regex: only include repos whose names match
#   EXCLUDE_FILTER  — regex: exclude repos whose names match
#   SKIP_FORKS      — true | false (default: false)
#   SKIP_ARCHIVED   — true | false (default: false)
#   SKIP_PRIVATE    — true | false (default: false)
#
# Import env vars:
#   IMPORT_FILE     — manifest file to read (default: repos.manifest)
#   TARGET_ORG      — GitHub org to import into (default: Interested-Deving-1896)
#   ONGOING_SYNC    — true | false — register each repo in registered-imports.json
#   DRY_RUN         — true | false — print what would be done without doing it

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${MODE:?MODE is required (export|import)}"

EXPORT_ORG="${EXPORT_ORG:-}"
EXPORT_FILE="${EXPORT_FILE:-repos.manifest}"
EXPORT_PLATFORM="${EXPORT_PLATFORM:-github}"
SOURCE_TOKEN="${SOURCE_TOKEN:-$GH_TOKEN}"
SOURCE_BASE_URL="${SOURCE_BASE_URL:-}"
INCLUDE_FILTER="${INCLUDE_FILTER:-}"
EXCLUDE_FILTER="${EXCLUDE_FILTER:-}"
SKIP_FORKS="${SKIP_FORKS:-false}"
SKIP_ARCHIVED="${SKIP_ARCHIVED:-false}"
SKIP_PRIVATE="${SKIP_PRIVATE:-false}"

IMPORT_FILE="${IMPORT_FILE:-repos.manifest}"
TARGET_ORG="${TARGET_ORG:-Interested-Deving-1896}"
ONGOING_SYNC="${ONGOING_SYNC:-false}"
DRY_RUN="${DRY_RUN:-false}"

GH_API="https://api.github.com"

info()  { echo "[repo-manifest] $*"; }
warn()  { echo "[repo-manifest][warn] $*" >&2; }
error() { echo "[repo-manifest][error] $*" >&2; exit 1; }
sanitize() { sed "s/${GH_TOKEN}/***TOKEN***/g" | sed "s/${SOURCE_TOKEN}/***TOKEN***/g"; }

gh_api() {
  curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$@"
}

# ── Export ────────────────────────────────────────────────────────────────────

do_export() {
  : "${EXPORT_ORG:?EXPORT_ORG is required for export mode}"

  info "Scanning ${EXPORT_PLATFORM}/${EXPORT_ORG} ..."

  local tmp_manifest
  tmp_manifest=$(mktemp)

  {
    echo "# repo-manifest — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# platform: ${EXPORT_PLATFORM}  org: ${EXPORT_ORG}"
    echo ""
  } > "$tmp_manifest"

  local count=0
  local page=1

  while true; do
    local result url

    case "$EXPORT_PLATFORM" in
      github)
        url="${SOURCE_BASE_URL:-https://api.github.com}/orgs/${EXPORT_ORG}/repos?per_page=100&page=${page}"
        result=$(curl -sf \
          -H "Authorization: token ${SOURCE_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          "$url") || break
        local batch_count
        batch_count=$(echo "$result" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
        [[ "$batch_count" -eq 0 ]] && break
        echo "$result" | python3 -c "
import json,sys
repos = json.load(sys.stdin)
skip_forks    = '${SKIP_FORKS}'    == 'true'
skip_archived = '${SKIP_ARCHIVED}' == 'true'
skip_private  = '${SKIP_PRIVATE}'  == 'true'
include_re    = '${INCLUDE_FILTER}'
exclude_re    = '${EXCLUDE_FILTER}'
import re
for r in repos:
    if skip_forks    and r.get('fork'):       continue
    if skip_archived and r.get('archived'):   continue
    if skip_private  and r.get('private'):    continue
    name = r['name']
    if include_re and not re.search(include_re, name): continue
    if exclude_re and     re.search(exclude_re, name): continue
    print(f\"{name} {r['clone_url']}\")
" >> "$tmp_manifest"
        ;;

      gitlab)
        local base="${SOURCE_BASE_URL:-https://gitlab.com}"
        url="${base}/api/v4/groups/${EXPORT_ORG}/projects?per_page=100&page=${page}&include_subgroups=true"
        result=$(curl -sf \
          ${SOURCE_TOKEN:+-H "PRIVATE-TOKEN: ${SOURCE_TOKEN}"} \
          "$url") || break
        local batch_count
        batch_count=$(echo "$result" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
        [[ "$batch_count" -eq 0 ]] && break
        echo "$result" | python3 -c "
import json,sys,re
repos = json.load(sys.stdin)
skip_forks    = '${SKIP_FORKS}'    == 'true'
skip_archived = '${SKIP_ARCHIVED}' == 'true'
skip_private  = '${SKIP_PRIVATE}'  == 'true'
include_re    = '${INCLUDE_FILTER}'
exclude_re    = '${EXCLUDE_FILTER}'
for r in repos:
    if skip_forks    and r.get('forked_from_project'): continue
    if skip_archived and r.get('archived'):            continue
    if skip_private  and r.get('visibility','') == 'private': continue
    name = r['path']
    if include_re and not re.search(include_re, name): continue
    if exclude_re and     re.search(exclude_re, name): continue
    print(f\"{name} {r['http_url_to_repo']}\")
" >> "$tmp_manifest"
        ;;

      bitbucket)
        url="${SOURCE_BASE_URL:-https://api.bitbucket.org}/2.0/repositories/${EXPORT_ORG}?pagelen=100&page=${page}"
        result=$(curl -sf \
          ${SOURCE_TOKEN:+-H "Authorization: Bearer ${SOURCE_TOKEN}"} \
          "$url") || break
        local batch_count
        batch_count=$(echo "$result" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('values',[])))" 2>/dev/null || echo 0)
        [[ "$batch_count" -eq 0 ]] && break
        echo "$result" | python3 -c "
import json,sys,re
data = json.load(sys.stdin)
skip_forks   = '${SKIP_FORKS}'   == 'true'
skip_private = '${SKIP_PRIVATE}' == 'true'
include_re   = '${INCLUDE_FILTER}'
exclude_re   = '${EXCLUDE_FILTER}'
for r in data.get('values',[]):
    if skip_forks   and r.get('parent'):      continue
    if skip_private and r.get('is_private'):  continue
    name = r['slug']
    if include_re and not re.search(include_re, name): continue
    if exclude_re and     re.search(exclude_re, name): continue
    clone_url = next((l['href'] for l in r.get('links',{}).get('clone',[]) if l.get('name')=='https'), '')
    print(f\"{name} {clone_url}\")
" >> "$tmp_manifest"
        ;;

      gitea)
        local base="${SOURCE_BASE_URL:?SOURCE_BASE_URL required for gitea}"
        url="${base}/api/v1/orgs/${EXPORT_ORG}/repos?limit=50&page=${page}"
        result=$(curl -sf \
          ${SOURCE_TOKEN:+-H "Authorization: token ${SOURCE_TOKEN}"} \
          "$url") || break
        local batch_count
        batch_count=$(echo "$result" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
        [[ "$batch_count" -eq 0 ]] && break
        echo "$result" | python3 -c "
import json,sys,re
repos = json.load(sys.stdin)
skip_forks    = '${SKIP_FORKS}'    == 'true'
skip_archived = '${SKIP_ARCHIVED}' == 'true'
skip_private  = '${SKIP_PRIVATE}'  == 'true'
include_re    = '${INCLUDE_FILTER}'
exclude_re    = '${EXCLUDE_FILTER}'
for r in repos:
    if skip_forks    and r.get('fork'):     continue
    if skip_archived and r.get('archived'): continue
    if skip_private  and r.get('private'):  continue
    name = r['name']
    if include_re and not re.search(include_re, name): continue
    if exclude_re and     re.search(exclude_re, name): continue
    print(f\"{name} {r['clone_url']}\")
" >> "$tmp_manifest"
        ;;

      *) error "Unsupported platform: ${EXPORT_PLATFORM}" ;;
    esac

    (( page++ ))
  done

  count=$(grep -c '^[^#]' "$tmp_manifest" 2>/dev/null || echo 0)
  mv "$tmp_manifest" "$EXPORT_FILE"

  info "Exported ${count} repos to ${EXPORT_FILE}"
  cat "$EXPORT_FILE"
}

# ── Import ────────────────────────────────────────────────────────────────────

do_import() {
  [[ -f "$IMPORT_FILE" ]] || error "Manifest file not found: ${IMPORT_FILE}"

  info "Importing from ${IMPORT_FILE} into ${TARGET_ORG} ..."
  echo ""

  local imported=0 skipped=0 failed=0

  while IFS= read -r line; do
    # Skip comments and blank lines
    [[ -z "$line" || "$line" == \#* ]] && continue

    local name clone_url
    name=$(echo "$line" | awk '{print $1}')
    clone_url=$(echo "$line" | awk '{print $2}')

    [[ -z "$name" || -z "$clone_url" ]] && continue

    info "── ${name} ──"

    if [[ "$DRY_RUN" == "true" ]]; then
      info "  [dry-run] would clone ${clone_url} → ${TARGET_ORG}/${name}"
      (( skipped++ ))
      continue
    fi

    # Check if already exists
    local exists
    exists=$(gh_api "${GH_API}/repos/${TARGET_ORG}/${name}" 2>/dev/null \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")

    if [[ -n "$exists" ]]; then
      info "  Already exists — skipping"
      (( skipped++ ))
      continue
    fi

    local work_dir
    work_dir=$(mktemp -d)

    # Inject auth into URL
    local auth_url="$clone_url"
    if [[ "$clone_url" == https://github.com/* ]]; then
      auth_url="${clone_url/https:\/\//https://${GH_TOKEN}@}"
    elif [[ -n "$SOURCE_TOKEN" && "$clone_url" == https://* ]]; then
      auth_url="${clone_url/https:\/\//https://oauth2:${SOURCE_TOKEN}@}"
    fi

    if ! git clone --mirror "$auth_url" "$work_dir" 2>&1 | sanitize; then
      warn "  Clone failed"
      rm -rf "$work_dir"
      (( failed++ ))
      continue
    fi

    # Create target repo
    gh_api -X POST "${GH_API}/orgs/${TARGET_ORG}/repos" \
      -d "{\"name\":\"${name}\",\"private\":false,\"auto_init\":false}" \
      > /dev/null 2>&1 || true

    local target_url="https://${GH_TOKEN}@github.com/${TARGET_ORG}/${name}.git"

    cd "$work_dir"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${script_dir}/branch-name-conv.sh"

    local push_ok=true
    push_branches_encoded "$target_url" 2>&1 | sanitize || push_ok=false
    git push "$target_url" '+refs/tags/*:refs/tags/*' 2>&1 | sanitize || true
    cd /
    rm -rf "$work_dir"

    if $push_ok; then
      info "  ✓ Imported"
      (( imported++ ))

      if [[ "$ONGOING_SYNC" == "true" ]]; then
        local json_file="${GITHUB_WORKSPACE:-/workspaces/fork-sync-all}/registered-imports.json"
        if [[ -f "$json_file" ]]; then
          python3 -c "
import json
path = '${json_file}'
entry = '${clone_url}'
data = json.load(open(path))
if entry not in data:
    data.append(entry)
    json.dump(data, open(path,'w'), indent=2)
"
        fi
      fi
    else
      warn "  Push failed"
      (( failed++ ))
    fi

  done < "$IMPORT_FILE"

  echo ""
  info "Complete — imported: ${imported} | skipped: ${skipped} | failed: ${failed}"
  [[ "$failed" -eq 0 ]] || exit 1
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "$MODE" in
  export) do_export ;;
  import) do_import ;;
  *) error "Unknown MODE: ${MODE} (expected: export|import)" ;;
esac
