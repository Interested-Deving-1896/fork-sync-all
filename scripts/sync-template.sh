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

info()  { echo "[sync-template] $*"; }
warn()  { echo "[warn] $*" >&2; }
error() { echo "[error] $*" >&2; exit 1; }
sanitize() { sed "s/${GH_TOKEN}/***TOKEN***/g"; }

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
)

is_excluded_path() {
  local rel="$1"
  for excl in "${EXCLUDED_PATHS[@]}"; do
    # Match exact file or any path under an excluded directory
    if [[ "$rel" == "$excl" || "$rel" == "$excl/"* ]]; then
      return 0
    fi
  done
  return 1
}

# ── GitHub API helpers ────────────────────────────────────────────────────────

gh_get() {
  curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$@"
}

gh_post() {
  local url="$1"; shift
  curl -sf -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    "$url" "$@"
}

# Commit a single file to a repo via the Contents API.
# Returns 0 on success (created or updated), 1 on failure.
# Skips if the file already exists and FORCE=false.
commit_file() {
  local owner="$1" repo="$2" path="$3" content_b64="$4" branch="$5"

  # Check if file already exists
  local existing_sha=""
  local existing
  existing=$(gh_get "${API}/repos/${owner}/${repo}/contents/${path}?ref=${branch}" 2>/dev/null) || true
  if [[ -n "$existing" ]]; then
    existing_sha=$(echo "$existing" | jq -r '.sha // empty' 2>/dev/null)
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
import sys, re

manifest_path = sys.argv[1]
profile_name  = sys.argv[2]

with open(manifest_path) as f:
    content = f.read()

# Minimal YAML parser: extract the named profile's include/exclude lists.
# Handles the indented block-sequence format used in template-manifest.yml.
lines = content.splitlines()

in_profiles   = False
in_profile    = False
in_include    = False
in_exclude    = False
includes      = []
excludes      = []

for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        continue

    if stripped == 'profiles:':
        in_profiles = True
        continue

    if not in_profiles:
        continue

    # Top-level profile key (2-space indent)
    m = re.match(r'^  (\S+):$', line)
    if m:
        if in_profile:
            break  # past our profile — done
        if m.group(1) == profile_name:
            in_profile = True
        in_include = False
        in_exclude = False
        continue

    if not in_profile:
        continue

    # include:/exclude: sub-keys (4-space indent)
    if re.match(r'^    include:\s*$', line):
        in_include = True
        in_exclude = False
        continue
    if re.match(r'^    exclude:\s*$', line):
        in_exclude = True
        in_include = False
        continue

    # List items under include/exclude (6-space indent)
    m = re.match(r'^      - (.+)$', line)
    if m:
        val = m.group(1).strip().strip('"\'')
        if in_include:
            includes.append(val)
        elif in_exclude:
            excludes.append(val)
        continue

    # Any other 4-space key resets include/exclude context
    if re.match(r'^    \S', line):
        in_include = False
        in_exclude = False

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

  find "$TEMPLATE_ROOT" -type f \
    | sed "s|^${TEMPLATE_ROOT}/||" \
    | while IFS= read -r rel; do
        is_excluded_path "$rel" && continue
        path_passes_filters "$rel" \
          "$profile_includes" "$profile_excludes" \
          "$consumer_excludes" "$consumer_includes" \
          || continue
        echo "$rel"
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

  local files_ok=0 files_failed=0
  while IFS= read -r rel; do
    local abs="${TEMPLATE_ROOT}/${rel}"
    [[ -f "$abs" ]] || continue

    local content_b64
    content_b64=$(base64 -w0 < "$abs")

    if commit_file "$GITHUB_OWNER" "$repo" "$rel" "$content_b64" "$branch"; then
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
        name          = re.sub(r'^\s*-\s*name:\s*', '', line).strip().strip('"\'')
        force         = None
        skip_osp      = None
        disabled      = None
        profile       = None
        exclude_paths = []
        include_paths = []
        in_entry      = True
        in_excludes   = False
        in_includes   = False
        continue

    if not in_entry:
        continue

    # Scalar fields
    m = re.match(r'^\s+(force|skip_osp_setup|disabled|profile):\s*(\S+)', line)
    if m:
        key, val = m.group(1), m.group(2).strip().strip('"\'')
        if   key == 'force':          force    = val
        elif key == 'skip_osp_setup': skip_osp = val
        elif key == 'disabled':       disabled = val
        elif key == 'profile':        profile  = val
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

  local total ok failed
  total=$(echo "$consumer_records" | grep -c '^---RECORD---$') || total=0
  ok=0; failed=0

  info "Found ${total} enabled consumer(s)."
  echo ""

  # Process each record
  while IFS= read -r record; do
    [[ -z "$record" ]] && continue

    local c_name c_force c_skip_osp c_profile c_excludes c_includes
    c_name=$(echo "$record" | sed -n '1p')
    c_force=$(echo "$record" | sed -n '2p')
    c_skip_osp=$(echo "$record" | sed -n '3p')
    c_profile=$(echo "$record" | sed -n '4p')
    c_excludes=$(echo "$record" | sed -n '5p')
    c_includes=$(echo "$record" | sed -n '6p')

    [[ -z "$c_name" ]] && continue

    # Per-consumer force overrides global FORCE
    local effective_force="$FORCE"
    [[ "$c_force" == "true" ]] && effective_force="true"

    info "──────────────────────────────────────────"
    info "Consumer: ${GITHUB_OWNER}/${c_name}"
    info "  profile=${c_profile}  force=${effective_force}  skip_osp_setup=${c_skip_osp}"
    [[ -n "$c_excludes" ]] && info "  exclude_paths: ${c_excludes}"
    [[ -n "$c_includes" ]] && info "  include_paths: ${c_includes}"

    # Verify repo exists
    local meta
    meta=$(gh_get "${API}/repos/${GITHUB_OWNER}/${c_name}" 2>/dev/null) || true
    if [[ -z "$meta" || "$(echo "$meta" | jq -r '.name // empty' 2>/dev/null)" != "$c_name" ]]; then
      warn "  Repo ${GITHUB_OWNER}/${c_name} not found — skipping."
      (( failed++ )) || true
      echo ""
      continue
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
        print(rec)
" <<< "$consumer_records")

  info "========================================"
  info "  Propagate complete"
  info "  Consumers synced: ${ok} | failed: ${failed}"
  info "========================================"

  [[ "$failed" -eq 0 ]]
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
fi
