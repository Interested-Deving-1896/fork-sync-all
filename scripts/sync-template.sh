#!/usr/bin/env bash
#
# Syncs fork-sync-all's full file tree into one or more target repos under
# GITHUB_OWNER, optionally creating new repos first.
#
# Three modes (mutually exclusive):
#
#   CREATE    — create a new repo in GITHUB_OWNER, push the template contents,
#               then run the full OSP/OOC mirror setup chain (same as add-mirror-repo
#               + setup-osp-mirrors for the new repo).
#
#   INJECT    — copy the current template tree into existing repos. Files that
#               already exist in the target are skipped unless FORCE=true.
#
#   PROPAGATE — read config/template-consumers.yml and sync the template into
#               every enabled consumer. Per-repo profile, force, skip_osp_setup,
#               exclude_paths, and include_paths flags from the YAML override
#               the global defaults.
#               Triggered automatically on push to main via sync-template.yml.
#
# In all modes every file in the fork-sync-all working tree (relative to
# TEMPLATE_ROOT) is committed to the target repo's default branch via the
# GitHub Contents API. The following paths are always excluded because they
# are repo-specific and must not be overwritten:
#
#   README.md
#   registered-imports.json
#   dep-graph/
#   .git/
#   .ona/
#
# Profile-based filtering:
#   When MANIFEST_FILE is set, each consumer can specify a `profile` that
#   controls which files are included/excluded. Profiles are defined in
#   config/template-manifest.yml. Per-consumer `exclude_paths` and
#   `include_paths` are applied on top of the profile's own filters.
#   If no profile is specified, `full` is assumed (all files pass through).
#
# Required env vars:
#   GH_TOKEN        — PAT with repo + admin:org + workflow scopes
#   GITHUB_OWNER    — target org (Interested-Deving-1896)
#   TEMPLATE_ROOT   — absolute path to the fork-sync-all checkout
#
# Required for CREATE mode:
#   NEW_REPO_NAME   — name for the new repo
#
# Required for INJECT mode:
#   TARGET_REPOS    — space-separated list of existing repo names
#
# Required for PROPAGATE mode:
#   CONSUMERS_FILE  — path to config/template-consumers.yml
#
# Optional:
#   MANIFEST_FILE   — path to config/template-manifest.yml (enables profiles)
#   PROFILE         — profile name for CREATE/INJECT modes (default: full)
#   FORCE           — "true" to overwrite files that already exist (default: false)
#   DRY_RUN         — "true" to report without writing (default: false)
#   PRIVATE         — "true" to create new repos as private (default: false)
#   DESCRIPTION     — description for new repo (CREATE mode only)
#   SKIP_OSP_SETUP  — "true" to skip OSP/OOC mirror chain after CREATE (default: false)
#   OSP_ORG         — mirror org (default: OpenOS-Project-OSP)
#   OOC_ORG         — mirror org (default: OpenOS-Project-Ecosystem-OOC)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_OWNER:?GITHUB_OWNER is required}"
: "${TEMPLATE_ROOT:?TEMPLATE_ROOT is required}"

DRY_RUN="${DRY_RUN:-false}"
FORCE="${FORCE:-false}"
PRIVATE="${PRIVATE:-false}"
DESCRIPTION="${DESCRIPTION:-}"
SKIP_OSP_SETUP="${SKIP_OSP_SETUP:-false}"
OSP_ORG="${OSP_ORG:-OpenOS-Project-OSP}"
OOC_ORG="${OOC_ORG:-OpenOS-Project-Ecosystem-OOC}"
NEW_REPO_NAME="${NEW_REPO_NAME:-}"
TARGET_REPOS="${TARGET_REPOS:-}"
CONSUMERS_FILE="${CONSUMERS_FILE:-}"
MANIFEST_FILE="${MANIFEST_FILE:-}"
PROFILE="${PROFILE:-full}"

API="https://api.github.com"


# ── Budget guard ─────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/includes/budget.sh"
source "$(dirname "${BASH_SOURCE[0]}")/includes/gh-api.sh"
budget_init

info()  { echo "[sync-template] $*" >&2; }
warn()  { echo "[warn] $*" >&2; }
error() { echo "[error] $*" >&2; exit 1; }
sanitize() { sed "s/${GH_TOKEN}/***TOKEN***/g"; }

# ── API quota guard ───────────────────────────────────────────────────────────
# Minimum remaining core API calls before we stop processing more consumers.
# Each consumer costs ~3-5 calls (SHA lookup + PUT per file). With 52 consumers
# and 2 files each, a full run costs ~200-300 calls. Stop at 300 to leave
# headroom for other scheduled workflows.
QUOTA_FLOOR="${QUOTA_FLOOR:-300}"

quota_ok() {
  local remaining
  remaining=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    "https://api.github.com/rate_limit" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['resources']['core']['remaining'])" \
    2>/dev/null) || return 0  # on error, assume ok
  if (( remaining < QUOTA_FLOOR )); then
    warn "API quota low (${remaining} remaining, floor=${QUOTA_FLOOR}) — stopping to preserve headroom."
    return 1
  fi
  return 0
}

# ── GraphQL repo existence prefetch ──────────────────────────────────────────
#
# Fetches existence + defaultBranchRef for all consumer repos in one GraphQL
# request before the propagation loop. Replaces 52 individual REST calls with 1.
# Results stored in _REPO_EXISTS["owner/repo"] = "true"|"false".
#
declare -A _REPO_EXISTS

prefetch_consumer_repos() {
  local owner="$1" repos_str="$2"
  [[ -z "$repos_str" ]] && return 0

  local -a repo_list
  read -r -a repo_list <<< "$repos_str"
  [[ ${#repo_list[@]} -eq 0 ]] && return 0

  local query_body=""
  for repo in "${repo_list[@]}"; do
    [[ -z "$repo" ]] && continue
    local alias
    alias=$(echo "$repo" | tr -- '-.' '__' | tr '[:upper:]' '[:lower:]')
    query_body+="
    ${alias}: repository(owner: \"${owner}\", name: \"${repo}\") {
      name
      defaultBranchRef { name }
    }"
  done
  [[ -z "$query_body" ]] && return 0

  local payload response
  payload=$(python3 -c "import json,sys; print(json.dumps({'query':'query {'+sys.argv[1]+'}'}))" "$query_body")
  response=$(curl -sf \
    -X POST "https://api.github.com/graphql" \
    -H "Authorization: bearer ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null) || {
    warn "GraphQL prefetch failed — will verify repos via REST per-consumer"
    return 0
  }

  local found=0
  for repo in "${repo_list[@]}"; do
    [[ -z "$repo" ]] && continue
    local alias
    alias=$(echo "$repo" | tr -- '-.' '__' | tr '[:upper:]' '[:lower:]')
    local repo_data
    repo_data=$(echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = (d.get('data') or {}).get('$alias')
print('true' if r and r.get('name') else 'false')
" 2>/dev/null)
    _REPO_EXISTS["${owner}/${repo}"]="${repo_data:-false}"
    [[ "$repo_data" == "true" ]] && (( found++ )) || true
  done
  info "GraphQL prefetch: ${found}/${#repo_list[@]} repos verified (1 API call)"
}

# ── Validate mode ─────────────────────────────────────────────────────────────

mode_count=0
[[ -n "$NEW_REPO_NAME"  ]] && (( mode_count++ )) || true
[[ -n "$TARGET_REPOS"   ]] && (( mode_count++ )) || true
[[ -n "$CONSUMERS_FILE" ]] && (( mode_count++ )) || true

if [[ "$mode_count" -eq 0 ]]; then
  error "Set NEW_REPO_NAME (create), TARGET_REPOS (inject), or CONSUMERS_FILE (propagate)."
fi
if [[ "$mode_count" -gt 1 ]]; then
  error "Only one of NEW_REPO_NAME, TARGET_REPOS, or CONSUMERS_FILE may be set."
fi

# ── Paths excluded from template sync ────────────────────────────────────────
# These are repo-specific files that must not be overwritten in targets.

EXCLUDED_PATHS=(
  "README.md"
  "registered-imports.json"
  "dep-graph"
  ".git"
  ".ona"
  # Never propagate compiled/generated artifacts
  "__pycache__"
  "*.pyc"
  "*.pyo"
  "node_modules"
  ".pytest_cache"
  # Never propagate fork-sync-all operational docs to consumers
  "DOCS"
  "AGENTS.md"
  # Never propagate project-specific source trees — these belong to their own
  # repos and must not be injected into unrelated consumers via the template.
  "lkm"
  "minidebian"
  "ramroot"
  # Never propagate project-specific build/packaging workflows that are only
  # meaningful in the repo they were written for. Consumers that genuinely need
  # these should define them locally rather than inheriting them from the template.
  ".github/workflows/appimage.yml"
  ".github/workflows/flatpak.yml"
  ".github/workflows/publish.yml"
  ".github/workflows/build-arm64.yml"
  ".github/workflows/bootstrap-triggers.yml"
  # Never propagate project-specific C/cmake/kernel CI — consumers have their
  # own ci.yml or ci.yaml that reflects their actual build system.
  ".github/workflows/ci.yml"
  # Never propagate project-specific code style configs — these are tuned for
  # C/kernel code and are wrong for shell/Python/YAML repos.
  ".clang-format"
  # .dockerignore and .editorconfig are safe to propagate but only if the
  # consumer doesn't already have one. Handled via force:false default.
  # .devcontainer/Dockerfile is btrfs-dwarfs-framework-specific — exclude globally.
  ".devcontainer/Dockerfile"
  # Never propagate fork-sync-all-only assets to consumers — docs-scaffold
  # entries are injected via explicit source:dest remaps in template-manifest.yml
  # and the scaffold-only guard in collect_template_files(). Propagating the
  # assets/ tree directly would overwrite consumer DOCS/ on every sync.
  "assets"
  # Never propagate the fork-sync-all dev environment to consumers — each repo
  # has its own devcontainer config (or none at all).
  ".devcontainer/devcontainer.json"
  ".devcontainer/features"
  # Never propagate the fork-sync-all GitLab CI pipeline to consumers — it runs
  # org-wide sync jobs (mirror-to-osp, reconcile-org-refs, sync-forks, etc.)
  # that are only meaningful on the fork-sync-all repo itself.
  ".gitlab-ci.yml"
  ".gitlab"
  # Never propagate fork-sync-all-only config files to consumers.
  "config/workflow-cost-profiles.yml"
  "config/workflow-sync.yml"
  # Never propagate the fork-sync-all pytest suite to consumers — these tests
  # validate fork-sync-all's own config/scripts and have no meaning elsewhere.
  "tests"
  # Never propagate fork-sync-all-only scripts to consumers — these are
  # validators and utilities for the fork-sync-all repo itself.
  "scripts/validate-cost-profiles.py"
  "scripts/validate-registered-imports.py"
  "scripts/validate-template-config.py"
  "scripts/validate-workflow-guards.py"
  "scripts/validate-workflows.sh"
  "scripts/generate-dep-graph.sh"
  "scripts/rl-manifest-to-md.py"
  "scripts/generate-gitlab-stubs.py"
  "scripts/init-kde-groups-mirror.py"
  "scripts/kde-path-to-gl-id.json"
)

is_excluded_path() {
  local rel="$1"
  local base
  base=$(basename "$rel")
  for excl in "${EXCLUDED_PATHS[@]}"; do
    # Exact match or directory prefix
    if [[ "$rel" == "$excl" || "$rel" == "$excl/"* ]]; then
      return 0
    fi
    # Glob match against basename (handles *.pyc, *.pyo etc.)
    # shellcheck disable=SC2254
    case "$base" in
      $excl) return 0 ;;
    esac
    # Glob match against any path component (handles __pycache__ anywhere)
    local part
    IFS='/' read -ra parts <<< "$rel"
    for part in "${parts[@]}"; do
      # shellcheck disable=SC2254
      case "$part" in
        $excl) return 0 ;;
      esac
    done
  done
  return 1
}

# ── GitHub API helpers ────────────────────────────────────────────────────────

gh_post() {
  local url="$1"; shift
  curl -sf -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    "$url" "$@"
}

# Fetch the full recursive tree for a repo and emit "path<TAB>sha" lines.
# One API call replaces N per-file /contents/ probes in commit_file().
# Usage: fetch_repo_tree <owner> <repo> <branch>
# Exit codes:
#   0 — success, tab-separated path/sha lines on stdout
#   1 — non-quota error (repo not found, network issue, etc.)
#   2 — quota exhausted (HTTP 403/429) — caller should abort, not fall back
fetch_repo_tree() {
  local owner="$1" repo="$2" branch="$3"
  local raw http_code
  raw=$(curl -s -w "\n__HTTP__%{http_code}" \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API}/repos/${owner}/${repo}/git/trees/${branch}?recursive=1" 2>/dev/null) || { echo ""; return 1; }
  http_code=$(echo "$raw" | grep -o '__HTTP__[0-9]*' | grep -o '[0-9]*')
  raw=$(echo "$raw" | sed 's/__HTTP__[0-9]*$//')
  if [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
    return 2
  fi
  if [[ "$http_code" != "200" ]]; then
    return 1
  fi
  # Emit "path<TAB>sha" for every blob — caller builds associative array
  # Pipe via stdin — avoids "Argument list too long" on large repos
  echo "$raw" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for item in d.get('tree', []):
    if item.get('type') == 'blob':
        print(item['path'] + '\t' + item['sha'])
"
}

# Commit a single file to a repo via the Contents API.
# Returns 0 on success (created or updated), 1 on failure.
# Skips if the file already exists and FORCE=false.
#
# $6 (optional): pre-fetched SHA for this path from fetch_repo_tree output.
#   Pass "" if the file is known to not exist, or omit to fall back to a
#   per-file /contents/ probe (legacy behaviour, costs 1 API call).
commit_file() {
  local owner="$1" repo="$2" path="$3" content_b64="$4" branch="$5"
  local prefetched_sha="${6-__UNSET__}"

  # Resolve existing SHA — use pre-fetched value when available
  local existing_sha=""
  if [[ "$prefetched_sha" == "__UNSET__" ]]; then
    # Legacy fallback: per-file REST probe (1 API call per file)
    local existing
    existing=$(gh_get "${API}/repos/${owner}/${repo}/contents/${path}?ref=${branch}" 2>/dev/null) || true
    if [[ -n "$existing" ]]; then
      existing_sha=$(echo "$existing" | jq -r '.sha // empty' 2>/dev/null)
    fi
  else
    existing_sha="$prefetched_sha"
  fi

  if [[ -n "$existing_sha" && "$FORCE" != "true" ]]; then
    info "    skip  ${path} (exists, FORCE=false)"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ -n "$existing_sha" ]]; then
      info "    [DRY_RUN] would update ${path}"
    else
      info "    [DRY_RUN] would create ${path}"
    fi
    return 0
  fi

  local payload
  if [[ -n "$existing_sha" ]]; then
    payload=$(jq -n \
      --arg msg "chore: sync template file ${path} [skip ci]" \
      --arg content "$content_b64" \
      --arg sha "$existing_sha" \
      --arg branch "$branch" \
      '{message: $msg, content: $content, sha: $sha, branch: $branch}')
  else
    payload=$(jq -n \
      --arg msg "chore: add template file ${path} [skip ci]" \
      --arg content "$content_b64" \
      --arg branch "$branch" \
      '{message: $msg, content: $content, branch: $branch}')
  fi

  local response http_code
  response=$(curl -sf -w "\n%{http_code}" \
    -X PUT \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    "${API}/repos/${owner}/${repo}/contents/${path}" \
    -d "$payload" 2>/dev/null) || true
  http_code=$(echo "$response" | tail -1)

  if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
    if [[ -n "$existing_sha" ]]; then
      info "    updated ${path}"
    else
      info "    created ${path}"
    fi
    return 0
  elif [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
    warn "    rate-limit on ${path} (HTTP ${http_code}) — skipping file (not counted as failure)"
    return 0
  else
    warn "    FAILED ${path} (HTTP ${http_code})"
    return 1
  fi
}

# ── Profile / manifest filtering ─────────────────────────────────────────────

# Resolve profile filters from the manifest file.
# Outputs two newline-separated lists to stdout, separated by a sentinel line:
#
#   <include patterns>
#   ---SENTINEL---
#   <exclude patterns>
#
# If MANIFEST_FILE is unset or the profile is "full" with no rules, both lists
# are empty (meaning: include everything, exclude nothing extra).
#
# Args: $1 = profile name
resolve_profile_filters() {
  local profile_name="${1:-full}"

  if [[ -z "$MANIFEST_FILE" || ! -f "$MANIFEST_FILE" ]]; then
    echo "---SENTINEL---"
    return 0
  fi

  python3 - "$MANIFEST_FILE" "$profile_name" << 'PYEOF'
import sys, yaml

manifest_path = sys.argv[1]
profile_name  = sys.argv[2]

with open(manifest_path) as f:
    manifest = yaml.safe_load(f)

profile = (manifest.get('profiles') or {}).get(profile_name) or {}
includes = [str(e) for e in (profile.get('include') or [])]
excludes = [str(e).split(':')[0] for e in (profile.get('exclude') or [])]

print('\n'.join(includes))
print('---SENTINEL---')
print('\n'.join(excludes))
PYEOF
}

# Test whether a relative path matches a glob pattern.
# Uses bash's extglob-free fnmatch via Python for portability.
# Returns 0 (match) or 1 (no match).
path_matches_pattern() {
  local path="$1" pattern="$2"
  python3 -c "
import fnmatch, sys
path    = sys.argv[1]
pattern = sys.argv[2]
# Match the full path or any suffix (for directory-prefix patterns like 'scripts/**')
if fnmatch.fnmatch(path, pattern):
    sys.exit(0)
# Also match if pattern ends with /** and path starts with the prefix
if pattern.endswith('/**'):
    prefix = pattern[:-3]
    if path == prefix or path.startswith(prefix + '/'):
        sys.exit(0)
# Match basename alone for simple filename patterns
import os
if fnmatch.fnmatch(os.path.basename(path), pattern):
    sys.exit(0)
sys.exit(1)
" "$path" "$pattern" 2>/dev/null
}

# Determine whether a relative path passes the combined profile + per-consumer
# filter set.
#
# Filter resolution order:
#   1. If profile has include patterns: path must match at least one → included.
#      If profile has no include patterns: path is included by default.
#   2. If path matches any profile exclude pattern → excluded.
#   3. If path matches any consumer exclude_paths pattern → excluded.
#   4. If path matches any consumer include_paths pattern → re-included
#      (overrides steps 2 and 3).
#
# Args:
#   $1 = relative path
#   $2 = newline-separated profile include patterns (may be empty)
#   $3 = newline-separated profile exclude patterns (may be empty)
#   $4 = newline-separated consumer exclude_paths (may be empty)
#   $5 = newline-separated consumer include_paths (may be empty)
#
# Returns 0 if the path should be synced, 1 if it should be skipped.
path_passes_filters() {
  local rel="$1"
  local profile_includes="$2"
  local profile_excludes="$3"
  local consumer_excludes="$4"
  local consumer_includes="$5"

  # Step 1: profile include whitelist
  if [[ -n "$profile_includes" ]]; then
    local matched=0
    while IFS= read -r pat; do
      [[ -z "$pat" ]] && continue
      path_matches_pattern "$rel" "$pat" && matched=1 && break
    done <<< "$profile_includes"
    [[ "$matched" -eq 0 ]] && return 1
  fi

  # Steps 2+3: profile and consumer excludes
  local excluded=0
  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    path_matches_pattern "$rel" "$pat" && excluded=1 && break
  done <<< "$profile_excludes"

  if [[ "$excluded" -eq 0 && -n "$consumer_excludes" ]]; then
    while IFS= read -r pat; do
      [[ -z "$pat" ]] && continue
      path_matches_pattern "$rel" "$pat" && excluded=1 && break
    done <<< "$consumer_excludes"
  fi

  # Step 4: consumer include_paths re-include
  if [[ "$excluded" -eq 1 && -n "$consumer_includes" ]]; then
    while IFS= read -r pat; do
      [[ -z "$pat" ]] && continue
      path_matches_pattern "$rel" "$pat" && excluded=0 && break
    done <<< "$consumer_includes"
  fi

  [[ "$excluded" -eq 0 ]]
}

# ── Collect template files ────────────────────────────────────────────────────

# Returns a list of relative paths for all files in TEMPLATE_ROOT that pass
# both the global exclusion list and the provided profile/consumer filters.
# One path per line.
#
# Args:
#   $1 = newline-separated profile include patterns (may be empty)
#   $2 = newline-separated profile exclude patterns (may be empty)
#   $3 = newline-separated consumer exclude_paths (may be empty)
#   $4 = newline-separated consumer include_paths (may be empty)
collect_template_files() {
  local profile_includes="${1:-}"
  local profile_excludes="${2:-}"
  local consumer_excludes="${3:-}"
  local consumer_includes="${4:-}"

  # Emit "source_rel\tdest_rel" pairs. For plain entries source==dest.
  # For "source:dest" remap entries, source is matched/read, dest is written.

  # First pass: emit remapped entries directly (don't need find for these)
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if [[ "$entry" == *:* ]]; then
      src="${entry%%:*}"
      dst="${entry#*:}"
      [[ -f "${TEMPLATE_ROOT}/${src}" ]] || continue
      is_excluded_path "$src" && continue
      echo -e "${src}\t${dst}"
    fi
  done <<< "$profile_includes"

  # Strip remap suffixes for plain path matching (remap entries already emitted)
  local plain_includes
  plain_includes=$(echo "$profile_includes" | sed 's|:.*||')

  find "$TEMPLATE_ROOT" -type f \
    | sed "s|^${TEMPLATE_ROOT}/||" \
    | while IFS= read -r rel; do
        is_excluded_path "$rel" && continue
        path_passes_filters "$rel" \
          "$plain_includes" "$profile_excludes" \
          "$consumer_excludes" "$consumer_includes" \
          || continue
        # Skip entries that are remap sources (already emitted above)
        while IFS= read -r entry; do
          [[ "$entry" == *:* ]] && [[ "${entry%%:*}" == "$rel" ]] && continue 2
        done <<< "$profile_includes"
        echo -e "${rel}\t${rel}"
      done \
    | sort
}

# ── Sync all template files into a single target repo ────────────────────────

# Args:
#   $1 = repo name
#   $2 = profile include patterns (newline-separated, may be empty)
#   $3 = profile exclude patterns (newline-separated, may be empty)
#   $4 = consumer exclude_paths (newline-separated, may be empty)
#   $5 = consumer include_paths (newline-separated, may be empty)
sync_into_repo() {
  local repo="$1"
  local profile_includes="${2:-}"
  local profile_excludes="${3:-}"
  local consumer_excludes="${4:-}"
  local consumer_includes="${5:-}"

  info "──────────────────────────────────────────"
  info "Syncing template → ${GITHUB_OWNER}/${repo}"

  # Get default branch
  local meta
  meta=$(gh_get "${API}/repos/${GITHUB_OWNER}/${repo}" 2>/dev/null) \
    || { warn "  Cannot read repo metadata — skipping"; return 1; }
  local branch
  branch=$(echo "$meta" | jq -r '.default_branch // "main"')
  info "  Default branch: ${branch}"

  # Fetch the full repo tree once — replaces one /contents/ probe per file.
  # Builds an associative array: tree_sha[path]=sha (empty string = not present)
  info "  Fetching repo tree (1 API call)..."
  declare -A tree_sha=()
  local tree_lines tree_rc
  tree_lines=$(fetch_repo_tree "$GITHUB_OWNER" "$repo" "$branch"); tree_rc=$?
  if [[ "$tree_rc" -eq 2 ]]; then
    warn "  Tree fetch hit quota limit (HTTP 403/429) — aborting repo to preserve headroom"
    return 1
  elif [[ "$tree_rc" -ne 0 || -z "$tree_lines" ]]; then
    warn "  Tree fetch failed (rc=${tree_rc}) — falling back to per-file probes"
  else
    while IFS=$'\t' read -r tpath tsha; do
      tree_sha["$tpath"]="$tsha"
    done <<< "$tree_lines"
    info "  Tree fetched: ${#tree_sha[@]} blobs indexed"
  fi

  local files_ok=0 files_failed=0
  while IFS=$'\t' read -r src_rel dest_rel; do
    [[ -z "$src_rel" ]] && continue
    local abs="${TEMPLATE_ROOT}/${src_rel}"
    [[ -f "$abs" ]] || continue

    local content_b64
    content_b64=$(base64 -w0 < "$abs")

    # Pass pre-fetched SHA if tree was loaded; fall back to legacy probe if not
    local sha_arg
    if [[ "${#tree_sha[@]}" -gt 0 ]]; then
      sha_arg="${tree_sha[$dest_rel]:-}"   # empty string = file not present in repo
    else
      sha_arg="__UNSET__"                  # triggers legacy per-file probe
    fi

    # Scaffold files (assets/*/ sources) are only written when the destination
    # does not already exist in the target repo. This prevents overwriting a
    # consumer's existing DOCS/ content or .ota/config.yml on subsequent syncs.
    if [[ "$src_rel" == assets/*/* && -n "$sha_arg" && "$sha_arg" != "__UNSET__" ]]; then
      info "  Skipping scaffold ${dest_rel} (already exists in ${repo})"
      (( files_ok++ )) || true
      continue
    fi

    if commit_file "$GITHUB_OWNER" "$repo" "$dest_rel" "$content_b64" "$branch" "$sha_arg"; then
      (( files_ok++ )) || true
    else
      (( files_failed++ )) || true
    fi

    # Brief pause to avoid secondary rate limits on rapid sequential writes
    [[ "$DRY_RUN" != "true" ]] && sleep 0.3

  done < <(collect_template_files \
    "$profile_includes" "$profile_excludes" \
    "$consumer_excludes" "$consumer_includes")

  info "  Files processed: ${files_ok} | failed: ${files_failed}"
  [[ "$files_failed" -eq 0 ]]
}

# ── CREATE mode ───────────────────────────────────────────────────────────────

run_create() {
  info "========================================"
  info "  CREATE mode: ${GITHUB_OWNER}/${NEW_REPO_NAME}"
  info "  DRY_RUN=${DRY_RUN}  FORCE=${FORCE}  PRIVATE=${PRIVATE}  PROFILE=${PROFILE}"
  info "========================================"
  echo ""

  # Resolve profile filters
  local filter_output profile_includes profile_excludes
  filter_output=$(resolve_profile_filters "$PROFILE")
  profile_includes=$(echo "$filter_output" | sed '/^---SENTINEL---$/,$d')
  profile_excludes=$(echo "$filter_output" | sed '1,/^---SENTINEL---$/d')

  # 1. Create the repo if it doesn't exist
  local existing
  existing=$(gh_get "${API}/repos/${GITHUB_OWNER}/${NEW_REPO_NAME}" 2>/dev/null) || true
  if [[ -n "$existing" && "$(echo "$existing" | jq -r '.name // empty')" == "$NEW_REPO_NAME" ]]; then
    info "Repo already exists — skipping creation, proceeding to template sync."
  else
    info "Creating ${GITHUB_OWNER}/${NEW_REPO_NAME}..."
    if [[ "$DRY_RUN" == "true" ]]; then
      info "  [DRY_RUN] would create repo"
    else
      local payload
      payload=$(jq -n \
        --arg name "$NEW_REPO_NAME" \
        --arg desc "${DESCRIPTION:-Managed by fork-sync-all}" \
        --argjson private "$([ "$PRIVATE" == "true" ] && echo true || echo false)" \
        '{name: $name, description: $desc, private: $private,
          has_issues: true, has_projects: false, has_wiki: false,
          auto_init: true}')
      local response http_code
      response=$(gh_post "${API}/orgs/${GITHUB_OWNER}/repos" -d "$payload")
      http_code=$(echo "$response" | tail -1)
      if [[ "$http_code" != "201" ]]; then
        error "Failed to create repo (HTTP ${http_code}): $(echo "$response" | sed '$d' | jq -r '.message // .' 2>/dev/null)"
      fi
      info "  Created (HTTP ${http_code}). Waiting for GitHub to initialise..."
      sleep 5
    fi
  fi
  echo ""

  # 2. Sync template files
  sync_into_repo "$NEW_REPO_NAME" "$profile_includes" "$profile_excludes" "" "" \
    || warn "Template sync had failures."
  echo ""

  # 3. OSP/OOC mirror setup
  if [[ "$SKIP_OSP_SETUP" == "true" ]]; then
    info "SKIP_OSP_SETUP=true — skipping mirror chain setup."
  else
    info "Running OSP/OOC mirror setup for ${NEW_REPO_NAME}..."
    if [[ "$DRY_RUN" == "true" ]]; then
      info "  [DRY_RUN] would run add-mirror-repo.sh + setup-osp-mirrors.sh"
    else
      local script_dir
      script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

      # add-mirror-repo: mirrors upstream → OSP and creates OOC stub
      REPO_URL="https://github.com/${GITHUB_OWNER}/${NEW_REPO_NAME}" \
      UPSTREAM_OWNER="$GITHUB_OWNER" \
      OSP_ORG="$OSP_ORG" \
      OOC_ORG="$OOC_ORG" \
        bash "${script_dir}/add-mirror-repo.sh" \
        || warn "add-mirror-repo.sh failed (non-fatal — hourly sync will catch up)"

      # setup-osp-mirrors: injects mirror-osp-to-ooc.yaml into the OSP repo
      UPSTREAM_OWNER="$GITHUB_OWNER" \
      OSP_ORG="$OSP_ORG" \
      OOC_ORG="$OOC_ORG" \
      REPO_FILTER="$NEW_REPO_NAME" \
        bash "${script_dir}/setup-osp-mirrors.sh" \
        || warn "setup-osp-mirrors.sh failed (non-fatal — setup-osp-mirrors.yml will retry)"
    fi
  fi
  echo ""

  info "========================================"
  info "  Done: ${GITHUB_OWNER}/${NEW_REPO_NAME}"
  if [[ "$SKIP_OSP_SETUP" != "true" && "$DRY_RUN" != "true" ]]; then
    info ""
    info "  Ongoing sync:"
    info "    :00  mirror-to-osp.yml pushes upstream → OSP (hourly)"
    info "    :45  setup-osp-mirrors.sh injects OSP→OOC workflow"
    info "    :15  mirror-osp-to-ooc.yaml pushes OSP → OOC (once injected)"
  fi
  info "========================================"
}

# ── INJECT mode ───────────────────────────────────────────────────────────────

run_inject() {
  info "========================================"
  info "  INJECT mode"
  info "  Targets: ${TARGET_REPOS}"
  info "  DRY_RUN=${DRY_RUN}  FORCE=${FORCE}  PROFILE=${PROFILE}"
  info "========================================"
  echo ""

  # Resolve profile filters (shared across all inject targets)
  local filter_output profile_includes profile_excludes
  filter_output=$(resolve_profile_filters "$PROFILE")
  profile_includes=$(echo "$filter_output" | sed '/^---SENTINEL---$/,$d')
  profile_excludes=$(echo "$filter_output" | sed '1,/^---SENTINEL---$/d')

  local ok=0 failed=0
  for repo in $TARGET_REPOS; do
    budget_check "${repo}" || break
    [[ -z "$repo" ]] && continue

    # Verify repo exists
    local meta
    meta=$(gh_get "${API}/repos/${GITHUB_OWNER}/${repo}" 2>/dev/null) || true
    if [[ -z "$meta" || "$(echo "$meta" | jq -r '.name // empty' 2>/dev/null)" != "$repo" ]]; then
      warn "Repo ${GITHUB_OWNER}/${repo} not found — skipping."
      (( failed++ )) || true
      continue
    fi

    if sync_into_repo "$repo" "$profile_includes" "$profile_excludes" "" ""; then
      (( ok++ )) || true
    else
      (( failed++ )) || true
    fi
    echo ""
  done

  info "========================================"
  info "  Inject complete"
  info "  Repos updated: ${ok} | failed: ${failed}"
  info "========================================"

  [[ "$failed" -eq 0 ]]
}

# ── PROPAGATE mode ───────────────────────────────────────────────────────────

run_propagate() {
  info "========================================"
  info "  PROPAGATE mode"
  info "  Consumers file: ${CONSUMERS_FILE}"
  info "  DRY_RUN=${DRY_RUN}"
  info "========================================"
  echo ""

  [[ -f "$CONSUMERS_FILE" ]] || error "CONSUMERS_FILE not found: ${CONSUMERS_FILE}"

  # Parse consumers from YAML using python3 (no PyYAML needed — stdlib only).
  # Outputs one record per enabled consumer. Fields are newline-separated within
  # a record; records are separated by "---RECORD---".
  #
  # Record format (one field per line):
  #   name
  #   force (true|false)
  #   skip_osp_setup (true|false)
  #   profile (name, default: full)
  #   exclude_paths (space-separated, may be empty)
  #   include_paths (space-separated, may be empty)
  #   af_registry_repo   (owner/repo, may be empty — upstream-sync profile only)
  #   af_registry_branch (branch, may be empty — upstream-sync profile only)
  #   af_registry_path   (path, may be empty — upstream-sync profile only)
  local consumer_records
  consumer_records=$(python3 - "$CONSUMERS_FILE" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Strip inline comments
lines = [re.sub(r'\s*#.*$', '', l) for l in content.splitlines()]

in_consumers = False
in_entry     = False
in_excludes  = False
in_includes  = False

name = force = skip_osp = disabled = profile = None
af_registry_repo = af_registry_branch = af_registry_path = None
exclude_paths = []
include_paths = []

def emit():
    if name and disabled != 'true':
        excl = ' '.join(exclude_paths) if exclude_paths else ''
        incl = ' '.join(include_paths) if include_paths else ''
        print(name)
        print(force    or 'false')
        print(skip_osp or 'false')
        print(profile  or 'full')
        print(excl)
        print(incl)
        print(af_registry_repo   or '')
        print(af_registry_branch or '')
        print(af_registry_path   or '')
        print('---RECORD---')

for line in lines:
    stripped = line.strip()
    if not stripped:
        continue

    if stripped == 'consumers:':
        in_consumers = True
        continue

    if not in_consumers:
        continue

    # New list entry (starts with "  - name:" at 2-space indent)
    if re.match(r'^\s*-\s*name:\s*\S', line):
        if in_entry:
            emit()
        name                = re.sub(r'^\s*-\s*name:\s*', '', line).strip().strip('"\'')
        force               = None
        skip_osp            = None
        disabled            = None
        profile             = None
        af_registry_repo    = None
        af_registry_branch  = None
        af_registry_path    = None
        exclude_paths       = []
        include_paths       = []
        in_entry            = True
        in_excludes         = False
        in_includes         = False
        continue

    if not in_entry:
        continue

    # Scalar fields
    m = re.match(r'^\s+(force|skip_osp_setup|disabled|profile|af_registry_repo|af_registry_branch|af_registry_path):\s*(\S+)', line)
    if m:
        key, val = m.group(1), m.group(2).strip().strip('"\'')
        if   key == 'force':               force               = val
        elif key == 'skip_osp_setup':      skip_osp            = val
        elif key == 'disabled':            disabled            = val
        elif key == 'profile':             profile             = val
        elif key == 'af_registry_repo':    af_registry_repo    = val
        elif key == 'af_registry_branch':  af_registry_branch  = val
        elif key == 'af_registry_path':    af_registry_path    = val
        in_excludes = False
        in_includes = False
        continue

    # List-header fields
    if re.match(r'^\s+exclude_paths:\s*$', line):
        in_excludes = True
        in_includes = False
        continue
    if re.match(r'^\s+include_paths:\s*$', line):
        in_includes = True
        in_excludes = False
        continue

    # List items
    m = re.match(r'^\s+-\s+(.+)$', line)
    if m:
        val = m.group(1).strip().strip('"\'')
        if in_excludes:
            exclude_paths.append(val)
        elif in_includes:
            include_paths.append(val)
        continue

    # Any other key at entry indent resets list context
    if re.match(r'^\s+\S', line):
        in_excludes = False
        in_includes = False

if in_entry:
    emit()
PYEOF
  ) || error "Failed to parse ${CONSUMERS_FILE}"

  if [[ -z "$consumer_records" ]]; then
    info "No enabled consumers found in ${CONSUMERS_FILE} — nothing to do."
    return 0
  fi

  local total ok failed quota_exhausted
  total=$(echo "$consumer_records" | grep -c '^---RECORD---$') || total=0
  ok=0; failed=0; quota_exhausted=0

  # Resume checkpoint — persists completed repo names across restarts.
  # Each successful sync appends the repo name; on restart we skip those repos.
  local checkpoint_file="${TMPDIR:-/tmp}/sync-template-checkpoint.txt"
  if [[ -f "$checkpoint_file" ]]; then
    local already_done
    already_done=$(wc -l < "$checkpoint_file" | tr -d ' ')
    info "Resuming from checkpoint: ${already_done} repo(s) already completed (${checkpoint_file})"
  else
    touch "$checkpoint_file"
  fi

  info "Found ${total} enabled consumer(s)."
  echo ""

  # Prefetch repo existence for all consumers in one GraphQL call (52 REST → 1)
  local all_consumer_names
  all_consumer_names=$(echo "$consumer_records" | grep -v '^---RECORD---$' | \
    python3 -c "
import sys
lines = sys.stdin.read().split('---RECORD---')
names = []
for block in lines:
    parts = [l.strip() for l in block.strip().splitlines() if l.strip()]
    if parts:
        names.append(parts[0])
print(' '.join(names))
" 2>/dev/null) || all_consumer_names=""
  [[ -n "$all_consumer_names" ]] && prefetch_consumer_repos "$GITHUB_OWNER" "$all_consumer_names"
  echo ""

  # Process each record (NUL-delimited so multi-line records are read whole)
  while IFS= read -r -d $'\0' record; do
    [[ -z "$record" ]] && continue

    local c_name c_force c_skip_osp c_profile c_excludes c_includes
    local c_af_registry_repo c_af_registry_branch c_af_registry_path
    c_name=$(printf '%s' "$record" | sed -n '1p')
    c_force=$(printf '%s' "$record" | sed -n '2p')
    c_skip_osp=$(printf '%s' "$record" | sed -n '3p')
    c_profile=$(printf '%s' "$record" | sed -n '4p')
    c_excludes=$(printf '%s' "$record" | sed -n '5p')
    c_includes=$(printf '%s' "$record" | sed -n '6p')
    c_af_registry_repo=$(printf '%s' "$record" | sed -n '7p')
    c_af_registry_branch=$(printf '%s' "$record" | sed -n '8p')
    c_af_registry_path=$(printf '%s' "$record" | sed -n '9p')

    [[ -z "$c_name" ]] && continue

    # Skip repos already completed in a previous run
    if grep -qxF "$c_name" "$checkpoint_file" 2>/dev/null; then
      info "  SKIP ${c_name} (already completed in previous run)"
      (( ok++ )) || true
      continue
    fi

    # Stop if API quota is too low to safely process another consumer
    if ! quota_ok; then
      quota_exhausted=1
      # Signal to ota-reconcile.sh that this repo was not processed due to
      # quota exhaustion. Reconcile reads this variable (check 4) to select
      # path C (quota-recovery) instead of path B (drift).
      if [[ "$DRY_RUN" != "true" ]]; then
        curl -sf -o /dev/null -X PUT \
          -H "Authorization: token ${GH_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          -H "Content-Type: application/json" \
          "${API}/repos/${GITHUB_OWNER}/${c_name}/actions/variables/OTA_SYNC_INCOMPLETE" \
          -d '{"name":"OTA_SYNC_INCOMPLETE","value":"true"}' 2>/dev/null || true
      fi
      break
    fi

    # Per-consumer force overrides global FORCE
    local effective_force="$FORCE"
    [[ "$c_force" == "true" ]] && effective_force="true"

    info "──────────────────────────────────────────"
    info "Consumer: ${GITHUB_OWNER}/${c_name}"
    info "  profile=${c_profile}  force=${effective_force}  skip_osp_setup=${c_skip_osp}"
    [[ -n "$c_excludes" ]] && info "  exclude_paths: ${c_excludes}"
    [[ -n "$c_includes" ]] && info "  include_paths: ${c_includes}"

    # Verify repo exists — use GraphQL prefetch cache if available, else REST fallback
    local repo_exists_val="${_REPO_EXISTS["${GITHUB_OWNER}/${c_name}"]:-}"
    if [[ -n "$repo_exists_val" ]]; then
      if [[ "$repo_exists_val" != "true" ]]; then
        warn "  Repo ${GITHUB_OWNER}/${c_name} not found (GraphQL prefetch) — skipping."
        (( failed++ )) || true
        echo ""
        continue
      fi
    else
      # Prefetch cache miss — fall back to individual REST call
      local meta meta_http
      meta=$(curl -sf -w "\n%{http_code}" \
        -H "Authorization: token ${GH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "${API}/repos/${GITHUB_OWNER}/${c_name}" 2>/dev/null) || true
      meta_http=$(echo "$meta" | tail -1)
      meta=$(echo "$meta" | sed '$d')
      if [[ "$meta_http" == "403" || "$meta_http" == "429" ]]; then
        warn "  Rate limit hit verifying ${c_name} — skipping (not counted as failure)."
        echo ""
        continue
      fi
      local meta_name
      meta_name=$(echo "$meta" | jq -r '.name // empty' 2>/dev/null)
      if [[ -z "$meta" || "${meta_name,,}" != "${c_name,,}" ]]; then
        warn "  Repo ${GITHUB_OWNER}/${c_name} not found (HTTP ${meta_http:-?}, got name='${meta_name}') — skipping."
        (( failed++ )) || true
        echo ""
        continue
      fi
    fi

    # Resolve profile filters
    local filter_output profile_includes profile_excludes
    filter_output=$(resolve_profile_filters "$c_profile")
    profile_includes=$(echo "$filter_output" | sed '/^---SENTINEL---$/,$d')
    profile_excludes=$(echo "$filter_output" | sed '1,/^---SENTINEL---$/d')

    # Convert space-separated consumer paths to newline-separated for filter functions
    local consumer_excl_nl consumer_incl_nl
    consumer_excl_nl=$(echo "$c_excludes" | tr ' ' '\n')
    consumer_incl_nl=$(echo "$c_includes" | tr ' ' '\n')

    # Temporarily override FORCE for this consumer
    local saved_force="$FORCE"
    FORCE="$effective_force"
    if sync_into_repo "$c_name" \
        "$profile_includes" "$profile_excludes" \
        "$consumer_excl_nl" "$consumer_incl_nl"; then
      (( ok++ )) || true
      # Write checkpoint so this repo is skipped on restart
      echo "$c_name" >> "$checkpoint_file"
      # Set FSA_MANAGED=true repo variable so bundled autonomous-fallback
      # workflows in the consumer repo know fork-sync-all is managing them.
      # Uses PUT (create-or-update). Failure is non-fatal — the mode-detection
      # helper falls back to the API existence check (Check A) if the var is absent.
      if [[ "$DRY_RUN" != "true" ]]; then
        local var_http
        var_http=$(curl -sf -o /dev/null -w "%{http_code}" \
          -X PUT \
          -H "Authorization: token ${GH_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          -H "Content-Type: application/json" \
          "${API}/repos/${GITHUB_OWNER}/${c_name}/actions/variables/FSA_MANAGED" \
          -d '{"name":"FSA_MANAGED","value":"true"}' 2>/dev/null) || var_http="000"
        if [[ "$var_http" == "201" || "$var_http" == "204" ]]; then
          info "  FSA_MANAGED=true set on ${c_name}"
        else
          warn "  Could not set FSA_MANAGED on ${c_name} (HTTP ${var_http}) — mode detection will use API fallback"
        fi

        # Set AF_REGISTRY_* vars for upstream-sync profile consumers so
        # sync-registry-backend.yml can self-configure without manual setup.
        # Uses per-consumer values from template-consumers.yml if present,
        # otherwise falls back to the penguins-eggs all-features defaults.
        if [[ "$c_profile" == "upstream-sync" ]]; then
          local reg_repo reg_branch reg_path
          reg_repo="${c_af_registry_repo:-${GITHUB_OWNER}/penguins-eggs}"
          reg_branch="${c_af_registry_branch:-all-features}"
          reg_path="${c_af_registry_path:-config/all-features-registry.json}"

          _set_repo_var() {
            local var_name="$1" var_value="$2"
            local http
            http=$(curl -sf -o /dev/null -w "%{http_code}" \
              -X PUT \
              -H "Authorization: token ${GH_TOKEN}" \
              -H "Accept: application/vnd.github+json" \
              -H "Content-Type: application/json" \
              "${API}/repos/${GITHUB_OWNER}/${c_name}/actions/variables/${var_name}" \
              -d "{\"name\":\"${var_name}\",\"value\":\"${var_value}\"}" 2>/dev/null) || http="000"
            if [[ "$http" == "201" || "$http" == "204" ]]; then
              info "  ${var_name}=${var_value} set on ${c_name}"
            else
              warn "  Could not set ${var_name} on ${c_name} (HTTP ${http})"
            fi
          }

          _set_repo_var "AF_REGISTRY_REPO"   "$reg_repo"
          _set_repo_var "AF_REGISTRY_BRANCH" "$reg_branch"
          _set_repo_var "AF_REGISTRY_PATH"   "$reg_path"
          unset -f _set_repo_var
        fi

        # Write .ota/version stamp so ota-reconcile.sh can detect currency
        # without diffing files. Failure is non-fatal.
        local fsa_sha_val="${FSA_SHA:-${GITHUB_SHA:-}}"
        if [[ -n "$fsa_sha_val" ]]; then
          local stamp_content existing_file_sha stamp_payload stamp_http
          stamp_content=$(printf 'fsa_sha: %s\nfsa_ref: main\nstamped_at: %s\nreconcile_path: A\n' \
            "$fsa_sha_val" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
          existing_file_sha=$(curl -sf \
            -H "Authorization: token ${GH_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            "${API}/repos/${GITHUB_OWNER}/${c_name}/contents/.ota/version" \
            2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || true)
          stamp_payload=$(python3 -c "
import json, base64, sys
content = base64.b64encode(sys.stdin.read().encode()).decode()
d = {'message': 'chore: update .ota/version [skip ci]', 'content': content}
sha = '$existing_file_sha'
if sha:
    d['sha'] = sha
print(json.dumps(d))
" <<< "$stamp_content")
          stamp_http=$(curl -sf -o /dev/null -w "%{http_code}" \
            -X PUT \
            -H "Authorization: token ${GH_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            -H "Content-Type: application/json" \
            "${API}/repos/${GITHUB_OWNER}/${c_name}/contents/.ota/version" \
            -d "$stamp_payload" 2>/dev/null) || stamp_http="000"
          if [[ "$stamp_http" == "200" || "$stamp_http" == "201" ]]; then
            info "  .ota/version stamped (${fsa_sha_val:0:8})"
          else
            warn "  Could not write .ota/version to ${c_name} (HTTP ${stamp_http}) — reconcile will handle on next run"
          fi
        fi
      fi
    else
      (( failed++ )) || true
    fi
    FORCE="$saved_force"
    echo ""

  done < <(python3 -c "
import sys
content = sys.stdin.read()
for rec in content.split('---RECORD---\n'):
    rec = rec.strip()
    if rec:
        sys.stdout.write(rec + '\0')
" <<< "$consumer_records")

  info "========================================"
  info "  Propagate complete"
  info "  Consumers synced: ${ok} | failed: ${failed}"
  [[ "$quota_exhausted" -eq 1 ]] && warn "  Stopped early — quota exhausted. Checkpoint preserved for resume."
  info "========================================"

  if [[ "$quota_exhausted" -eq 1 ]]; then
    # Incomplete run — preserve checkpoint so next invocation resumes
    return 1
  elif [[ "$failed" -eq 0 ]]; then
    # All consumers processed successfully — clear checkpoint
    rm -f "$checkpoint_file"
    return 0
  else
    return 1
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────

[[ "$DRY_RUN" == "true" ]] && info "Dry run — no writes will occur."
[[ "$FORCE"   == "true" ]] && info "Force mode — existing files will be overwritten."
echo ""

if [[ -n "$NEW_REPO_NAME" ]]; then
  run_create
elif [[ -n "$CONSUMERS_FILE" ]]; then
  run_propagate
else
  run_inject
budget_report
fi
