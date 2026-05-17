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
#               every enabled consumer. Per-repo force/skip_osp_setup flags
#               from the YAML override the global FORCE env var.
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

# ── Collect template files ────────────────────────────────────────────────────

# Returns a list of relative paths for all files in TEMPLATE_ROOT that are
# not excluded. One path per line.
collect_template_files() {
  find "$TEMPLATE_ROOT" -type f \
    | sed "s|^${TEMPLATE_ROOT}/||" \
    | while IFS= read -r rel; do
        is_excluded_path "$rel" && continue
        echo "$rel"
      done \
    | sort
}

# ── Sync all template files into a single target repo ────────────────────────

sync_into_repo() {
  local repo="$1"
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

  done < <(collect_template_files)

  info "  Files processed: ${files_ok} | failed: ${files_failed}"
  [[ "$files_failed" -eq 0 ]]
}

# ── CREATE mode ───────────────────────────────────────────────────────────────

run_create() {
  info "========================================"
  info "  CREATE mode: ${GITHUB_OWNER}/${NEW_REPO_NAME}"
  info "  DRY_RUN=${DRY_RUN}  FORCE=${FORCE}  PRIVATE=${PRIVATE}"
  info "========================================"
  echo ""

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
  sync_into_repo "$NEW_REPO_NAME" || warn "Template sync had failures."
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
  info "  DRY_RUN=${DRY_RUN}  FORCE=${FORCE}"
  info "========================================"
  echo ""

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

    if sync_into_repo "$repo"; then
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
  # Outputs one line per enabled consumer: name|force|skip_osp_setup
  local consumer_lines
  consumer_lines=$(python3 - "$CONSUMERS_FILE" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Strip comments
lines = [re.sub(r'\s*#.*$', '', l) for l in content.splitlines()]

# Find the consumers: list block
in_consumers = False
in_entry = False
name = force = skip_osp = disabled = None

def emit():
    if name and disabled != 'true':
        print(f"{name}|{force or 'false'}|{skip_osp or 'false'}")

for line in lines:
    stripped = line.strip()
    if not stripped:
        continue

    if stripped == 'consumers:':
        in_consumers = True
        continue

    if not in_consumers:
        continue

    # New list entry
    if re.match(r'^  - name:', stripped) or re.match(r'^- name:', stripped):
        if in_entry:
            emit()
        name     = re.sub(r'^-?\s*name:\s*', '', stripped).strip().strip('"\'')
        force    = None
        skip_osp = None
        disabled = None
        in_entry = True
        continue

    if in_entry:
        m = re.match(r'^\s*(force|skip_osp_setup|disabled):\s*(\S+)', line)
        if m:
            key, val = m.group(1), m.group(2).strip().strip('"\'')
            if key == 'force':        force    = val
            elif key == 'skip_osp_setup': skip_osp = val
            elif key == 'disabled':   disabled = val

if in_entry:
    emit()
PYEOF
  ) || error "Failed to parse ${CONSUMERS_FILE}"

  if [[ -z "$consumer_lines" ]]; then
    info "No enabled consumers found in ${CONSUMERS_FILE} — nothing to do."
    return 0
  fi

  local total ok failed
  total=$(echo "$consumer_lines" | grep -c '^') || total=0
  ok=0; failed=0

  info "Found ${total} enabled consumer(s)."
  echo ""

  while IFS='|' read -r repo consumer_force consumer_skip_osp; do
    [[ -z "$repo" ]] && continue

    # Per-consumer force overrides global FORCE
    local effective_force="$FORCE"
    [[ "$consumer_force" == "true" ]] && effective_force="true"

    info "──────────────────────────────────────────"
    info "Consumer: ${GITHUB_OWNER}/${repo}"
    info "  force=${effective_force}  skip_osp_setup=${consumer_skip_osp}"

    # Verify repo exists
    local meta
    meta=$(gh_get "${API}/repos/${GITHUB_OWNER}/${repo}" 2>/dev/null) || true
    if [[ -z "$meta" || "$(echo "$meta" | jq -r '.name // empty' 2>/dev/null)" != "$repo" ]]; then
      warn "  Repo ${GITHUB_OWNER}/${repo} not found — skipping."
      (( failed++ )) || true
      echo ""
      continue
    fi

    # Temporarily override FORCE for this consumer
    local saved_force="$FORCE"
    FORCE="$effective_force"
    if sync_into_repo "$repo"; then
      (( ok++ )) || true
    else
      (( failed++ )) || true
    fi
    FORCE="$saved_force"
    echo ""

  done <<< "$consumer_lines"

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
