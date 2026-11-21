#!/usr/bin/env bash
#
# Merges multiple git repositories into a single monorepo, preserving full
# commit history, tags, and Git LFS objects.
#
# Inspired by:
#   helpmatteo/multirepos-to-monorepo  — filter-repo + LFS + tag prefixing
#   sebmellen/monorepo-importer        — sequential merge approach
#   chrisdothtml/monorepo-import       — commit-replay for clean history
#   swingbit/mergeGitRepos             — YAML branch mapping
#   robinst/git-merge-repos            — N-parent merge commit (native bash impl)
#
# Strategy
# ────────
# For each source repo:
#   1. Clone it into a temp directory.
#   2. Run git filter-repo --to-subdirectory-filter <subdir> to rewrite all
#      commits so every file lives under <subdir>/.
#   3. Add it as a remote in the monorepo and fetch.
#   4. Merge with --allow-unrelated-histories into the target branch.
#
# N-parent merge (--nparent mode):
#   Instead of sequential merges, all source repos are fetched first, then
#   a single merge commit is created with N parents — one per source repo.
#   This produces a cleaner history graph but requires git 2.9+.
#
# Branch mapping:
#   BRANCH_MAP env var (JSON) controls which source branch maps to which
#   destination branch. Default: source default branch → MONOREPO_BRANCH.
#   Example: '{"develop":"main","release/1.0":"release-1.0"}'
#
# Required env vars:
#   GH_TOKEN          — GitHub PAT (repo + workflow scopes)
#   REPOS             — newline or space separated list of "url subdir" pairs
#                       e.g. "https://github.com/org/repo-a.git services/a"
#   MONOREPO_URL      — target monorepo clone URL (https)
#                       leave blank to auto-create in MONOREPO_OWNER
#
# Optional env vars:
#   MONOREPO_OWNER    — GitHub org for auto-create (default: Interested-Deving-1896)
#   MONOREPO_NAME     — repo name for auto-create
#   MONOREPO_BRANCH   — target branch in monorepo (default: main)
#   MONOREPO_PRIVATE  — true | false (default: false)
#   PREFIX_TAGS       — true | false — prefix tags with subdir name (default: true)
#   USE_GIT_LFS       — true | false — fetch and preserve LFS objects (default: false)
#   NPARENT           — true | false — single N-parent merge commit (default: false)
#   BRANCH_MAP        — JSON object mapping source branch → dest branch
#   SOURCE_TOKEN      — PAT for private source repos

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPOS:?REPOS is required — newline/space separated 'url subdir' pairs}"

MONOREPO_URL="${MONOREPO_URL:-}"
MONOREPO_OWNER="${MONOREPO_OWNER:-Interested-Deving-1896}"
MONOREPO_NAME="${MONOREPO_NAME:-monorepo}"
MONOREPO_BRANCH="${MONOREPO_BRANCH:-main}"
MONOREPO_PRIVATE="${MONOREPO_PRIVATE:-false}"
PREFIX_TAGS="${PREFIX_TAGS:-true}"
USE_GIT_LFS="${USE_GIT_LFS:-false}"
NPARENT="${NPARENT:-false}"
BRANCH_MAP="${BRANCH_MAP:-{}}"
SOURCE_TOKEN="${SOURCE_TOKEN:-}"
# When true, registers the monorepo in OSP mirror chain via add-mirror-repo.yml
MIRROR_MONOREPO="${MIRROR_MONOREPO:-false}"

GH_API="https://api.github.com"


# ── Budget guard ─────────────────────────────────────────────────────────────
# shellcheck source=includes/budget.sh
source "$(dirname "${BASH_SOURCE[0]}")/includes/budget.sh"
budget_init

info()  { echo "[merge-to-monorepo] $*" >&2; }
warn()  { echo "[merge-to-monorepo][warn] $*" >&2; }
error() { echo "[merge-to-monorepo][error] $*" >&2; exit 1; }

sanitize() {
  sed "s/${GH_TOKEN}/***TOKEN***/g" \
  | sed "s/${SOURCE_TOKEN:-NOTOKEN}/***TOKEN***/g"
}

# Use canonical gh_api with rate-limit retry, reset-aware backoff, 5xx retry.
source "$(dirname "${BASH_SOURCE[0]}")/includes/gh-api.sh"

# ── Dependency check ──────────────────────────────────────────────────────────

check_deps() {
  local missing=()
  command -v git          >/dev/null || missing+=(git)
  command -v git-filter-repo >/dev/null || missing+=(git-filter-repo)
  command -v python3      >/dev/null || missing+=(python3)
  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing dependencies: ${missing[*]}"
  fi
  if [[ "$USE_GIT_LFS" == "true" ]]; then
    command -v git-lfs >/dev/null || error "git-lfs required when USE_GIT_LFS=true"
  fi
  info "git $(git --version | awk '{print $3}')"
  info "git-filter-repo $(git filter-repo --version 2>/dev/null || echo 'ok')"
}

# ── Branch resolution ─────────────────────────────────────────────────────────

# Returns the default branch of a cloned repo
detect_default_branch() {
  local repo_dir="$1"
  # Try symbolic-ref first (works on non-bare clones)
  git -C "$repo_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's|refs/remotes/origin/||' \
    || git -C "$repo_dir" remote show origin 2>/dev/null \
       | grep 'HEAD branch' | awk '{print $NF}' \
    || echo "main"
}

# Map a source branch name to a destination branch using BRANCH_MAP JSON
map_branch() {
  local src="$1"
  python3 -c '
import json, subprocess, sys
try:
    mapping = json.loads(sys.argv[1])
except (TypeError, ValueError):
    raise SystemExit("BRANCH_MAP must be valid JSON")
if not isinstance(mapping, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in mapping.items()):
    raise SystemExit("BRANCH_MAP must map string branch names to string branch names")
target = mapping.get(sys.argv[2], sys.argv[3])
for branch in (sys.argv[2], target):
    if not branch or subprocess.run(["git", "check-ref-format", "--branch", branch], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        raise SystemExit("Invalid branch name in branch mapping")
print(target)
' "$BRANCH_MAP" "$src" "$MONOREPO_BRANCH"
}

# ── Monorepo setup ────────────────────────────────────────────────────────────

setup_monorepo() {
  local mono_dir="$1"

  if [[ -n "$MONOREPO_URL" ]]; then
    info "Cloning existing monorepo: ${MONOREPO_URL} ..."
    local auth_url="${MONOREPO_URL/https:\/\//https://${GH_TOKEN}@}"
    git clone "$auth_url" "$mono_dir" 2>&1 | sanitize \
      || error "Destination clone failed; refusing to continue"
  else
    info "Auto-creating monorepo ${MONOREPO_OWNER}/${MONOREPO_NAME} ..."
    # Create on GitHub if it doesn't exist
    local exists
    exists=$(gh_api GET "${GH_API}/repos/${MONOREPO_OWNER}/${MONOREPO_NAME}" 2>/dev/null \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")
    if [[ -z "$exists" ]]; then
      local create_response
      create_response=$(gh_create_repo "${MONOREPO_OWNER}" "${MONOREPO_NAME}" "${MONOREPO_PRIVATE}") \
        || error "Failed to create ${MONOREPO_OWNER}/${MONOREPO_NAME}; refusing to continue"
      local created_owner
      created_owner=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("owner",{}).get("login",""))' <<< "$create_response")
      [[ "$created_owner" == "$MONOREPO_OWNER" ]] \
        || error "Repository creation owner mismatch (expected ${MONOREPO_OWNER}, got ${created_owner:-unknown})"
      sleep 3  # let GitHub initialise the repo
    fi
    MONOREPO_URL="https://github.com/${MONOREPO_OWNER}/${MONOREPO_NAME}.git"
    local auth_url="https://${GH_TOKEN}@github.com/${MONOREPO_OWNER}/${MONOREPO_NAME}.git"
    git clone "$auth_url" "$mono_dir" 2>&1 | sanitize \
      || error "Destination clone failed; refusing to continue"
  fi

  # Ensure target branch exists
  if ! git -C "$mono_dir" rev-parse --verify "$MONOREPO_BRANCH" >/dev/null 2>&1; then
    git -C "$mono_dir" checkout -b "$MONOREPO_BRANCH" \
      || error "Unable to create destination branch ${MONOREPO_BRANCH}"
  else
    git -C "$mono_dir" checkout "$MONOREPO_BRANCH" \
      || error "Unable to check out destination branch ${MONOREPO_BRANCH}"
  fi

  # Ensure at least one commit exists (needed for merges)
  if ! git -C "$mono_dir" rev-parse HEAD >/dev/null 2>&1; then
    git -C "$mono_dir" commit --allow-empty -m "chore: initialise monorepo" \
      || error "Unable to initialize destination repository"
  fi
}

# ── Single repo preparation ───────────────────────────────────────────────────

prepare_source_repo() {
  local url="$1" subdir="$2" work_dir="$3"

  # Validate subdir (prevent path traversal)
  if [[ "$subdir" == ".." || "$subdir" == /* || "$subdir" == *..* ]]; then
    warn "Unsafe subdir '${subdir}' — skipping"
    return 1
  fi

  info "  Cloning ${url} ..."
  local auth_url="$url"
  if [[ -n "$SOURCE_TOKEN" && "$url" == https://* ]]; then
    auth_url="${url/https:\/\//https://oauth2:${SOURCE_TOKEN}@}"
  elif [[ "$url" == https://github.com/* ]]; then
    auth_url="${url/https:\/\//https://${GH_TOKEN}@}"
  fi

  if ! git clone "$auth_url" "$work_dir" 2>&1 | sanitize; then
    warn "  Clone failed for ${url}"
    return 1
  fi

  # Skip empty repos
  if ! git -C "$work_dir" rev-parse HEAD >/dev/null 2>&1; then
    warn "  Empty repo — skipping ${url}"
    return 1
  fi

  if [[ "$USE_GIT_LFS" == "true" ]]; then
    info "  Fetching LFS objects ..."
    git -C "$work_dir" lfs fetch --all \
      || { warn "Git LFS object fetch failed for ${url}"; return 1; }
  fi

  # Prefix tags to avoid collisions
  if [[ "$PREFIX_TAGS" == "true" ]]; then
    local safe_subdir="${subdir//\//-}"
    while IFS= read -r tag; do
      [[ -z "$tag" ]] && continue
      git -C "$work_dir" tag "${safe_subdir}-${tag}" "$tag" 2>/dev/null || true
      git -C "$work_dir" tag -d "$tag" 2>/dev/null || true
    done < <(git -C "$work_dir" tag -l)
  fi

  # Rewrite history: move all files under subdir/
  info "  Rewriting history into ${subdir}/ ..."
  if ! git -C "$work_dir" filter-repo \
    --to-subdirectory-filter "$subdir" \
    --force \
    2>&1 | tail -3; then
    warn "History rewrite failed for ${url}"
    return 1
  fi

  return 0
}

# ── N-parent merge ────────────────────────────────────────────────────────────

# Creates a single merge commit with N parents — one per source repo.
# All source trees are merged into the monorepo in one commit.
nparent_merge() {
  local mono_dir="$1"
  shift
  local -a source_dirs=("$@")
  # shellcheck disable=SC2034
  local -a source_subdirs=("$@")  # parallel array — populated below from global subdirs[]

  info "Building N-parent merge commit (${#source_dirs[@]} parents) ..."

  # Fetch all source repos as remotes so their objects are available in the
  # monorepo's object store (needed for commit-tree parent resolution).
  local parent_shas=()
  local remote_idx=0
  for src_dir in "${source_dirs[@]}"; do
    budget_check "$src_dir" || { warn "Budget guard stopped N-parent source collection"; return 1; }
    local remote_name="source-${remote_idx}"
    git -C "$mono_dir" remote add "$remote_name" "$src_dir" 2>/dev/null \
      || { warn "Unable to register N-parent source remote"; return 1; }
    git -C "$mono_dir" fetch "$remote_name" --tags \
    || { warn "Fetch failed for source directory ${src_dir}"; return 1; }
    local src_head
    src_head=$(git -C "$src_dir" rev-parse HEAD 2>/dev/null || echo "")
    [[ -n "$src_head" ]] || { warn "Unable to resolve source commit for ${src_dir}"; return 1; }
    parent_shas+=("$src_head")
    (( remote_idx++ ))
  done

  if [[ ${#parent_shas[@]} -eq 0 ]]; then
    warn "No valid source commits found for N-parent merge"
    return 1
  fi

  local mono_head
  mono_head=$(git -C "$mono_dir" rev-parse HEAD 2>/dev/null || echo "")

  # Build the merged tree in a temporary index file so we never touch the
  # monorepo's working index during construction.
  #
  # Strategy:
  #   1. Start with the monorepo's current tree (preserves any existing files).
  #   2. For each source repo, read its already-rewritten tree (filter-repo has
  #      already placed all files under <subdir>/) using --prefix="" into the
  #      temp index. Because each source lives in its own subdirectory, there
  #      are no path collisions between sources. The only possible collision is
  #      with an existing monorepo file at the same subdir path — detected and
  #      reported below rather than silently overwritten.
  local tmp_index
  tmp_index=$(mktemp)
  trap 'rm -f "${tmp_index}"' RETURN

  # Seed the temp index from the monorepo's current tree
  GIT_INDEX_FILE="$tmp_index" git -C "$mono_dir" read-tree HEAD 2>/dev/null \
    || { warn "Unable to seed N-parent index from destination HEAD"; return 1; }

  local collision_found=false
  for (( i=0; i<${#source_dirs[@]}; i++ )); do
    local src_dir="${source_dirs[$i]}"
    local subdir="${src_subdirs[$i]}"  # aligned with successfully prepared source directories

    local src_tree
    src_tree=$(git -C "$src_dir" rev-parse 'HEAD^{tree}' 2>/dev/null || echo "")
    [[ -n "$src_tree" ]] || { warn "Unable to resolve source tree"; return 1; }

    # Check for path collisions before writing: list files in the source tree
    # and see if any already exist in the temp index under the same path.
    # filter-repo has already prefixed everything with <subdir>/, so we check
    # for <subdir>/ entries in the current index.
    local existing_at_subdir
    existing_at_subdir=$(GIT_INDEX_FILE="$tmp_index" git -C "$mono_dir" \
      ls-files --cached -- "${subdir}/" 2>/dev/null | head -1)

    if [[ -n "$existing_at_subdir" ]]; then
      warn "  Path collision: ${subdir}/ already exists in monorepo index."
      warn "  N-parent import is unsafe with a destination collision; aborting."
      return 1
    fi

    # No collision — read the source tree into the temp index.
    # --prefix="" is correct here because filter-repo already placed all files
    # under <subdir>/, so the tree's root IS the monorepo root for this source.
    GIT_INDEX_FILE="$tmp_index" git -C "$mono_dir" \
      read-tree --prefix="" -i "$src_tree" 2>/dev/null \
      || { warn "  read-tree failed for ${subdir}; aborting N-parent import"; return 1; }

    info "  Added ${subdir}/ to N-parent tree."
  done

  # Every collected source must contribute exactly one parent.
  local -a valid_parents=("${parent_shas[@]}")
  if [[ ${#valid_parents[@]} -ne ${#source_dirs[@]} ]]; then
    warn "N-parent source/parent count mismatch; aborting"
    return 1
  fi

  # Write the merged tree from the temp index
  local new_tree
  new_tree=$(GIT_INDEX_FILE="$tmp_index" git -C "$mono_dir" write-tree)

  # Build parent list: current monorepo HEAD + all valid source HEADs
  local parent_args=()
  [[ -n "$mono_head" ]] && parent_args+=(-p "$mono_head")
  for sha in "${valid_parents[@]}"; do
    parent_args+=(-p "$sha")
  done

  # Create the N-parent merge commit
  local commit_sha
  commit_sha=$(git -C "$mono_dir" commit-tree "$new_tree" \
    "${parent_args[@]}" \
    -m "chore: merge ${#valid_parents[@]} repos into monorepo (N-parent)")

  git -C "$mono_dir" update-ref "refs/heads/${MONOREPO_BRANCH}" "$commit_sha"
  # Update the working tree to match
  git -C "$mono_dir" checkout "$MONOREPO_BRANCH" -- 2>/dev/null || true

  info "N-parent merge commit: ${commit_sha} (${#valid_parents[@]} parents)"

  return 0
}

# ── Sequential merge ──────────────────────────────────────────────────────────

sequential_merge() {
  local mono_dir="$1" src_dir="$2" subdir="$3" url="$4"

  local remote_name
  remote_name="src-$(echo "$subdir" | tr '/' '-')"

  git -C "$mono_dir" remote add "$remote_name" "$src_dir" 2>/dev/null \
    || git -C "$mono_dir" remote set-url "$remote_name" "$src_dir" \
    || { warn "Unable to register source remote ${remote_name}"; return 1; }
  git -C "$mono_dir" fetch "$remote_name" --tags \
    || { warn "Fetch failed for ${url}"; return 1; }

  local src_branch
  src_branch=$(detect_default_branch "$src_dir")
  local dest_branch
  dest_branch=$(map_branch "$src_branch")

  # Ensure dest branch exists
  if ! git -C "$mono_dir" rev-parse --verify "$dest_branch" >/dev/null 2>&1; then
    git -C "$mono_dir" checkout -b "$dest_branch" 2>/dev/null \
      || { warn "Unable to create destination branch ${dest_branch}"; return 1; }
  else
    git -C "$mono_dir" checkout "$dest_branch" 2>/dev/null \
      || { warn "Unable to check out destination branch ${dest_branch}"; return 1; }
  fi

  info "  Merging ${subdir} (${src_branch} → ${dest_branch}) ..."
  if ! git -C "$mono_dir" merge \
    --allow-unrelated-histories \
    --no-edit \
    -m "chore: merge ${url} into ${subdir}/" \
    "${remote_name}/${src_branch}" \
    2>&1 | tail -5; then
    warn "Merge conflict in ${subdir}; aborting rather than recording an ours-only merge"
    git -C "$mono_dir" merge --abort 2>/dev/null || true
    git -C "$mono_dir" remote remove "$remote_name" 2>/dev/null || true
    return 1
  fi
  git -C "$mono_dir" remote remove "$remote_name" 2>/dev/null || true
  return 0

  git -C "$mono_dir" remote remove "$remote_name" 2>/dev/null || true
}

# ── Main ──────────────────────────────────────────────────────────────────────

check_deps

workspace=$(mktemp -d)
trap 'rm -rf "${workspace}"' EXIT

mono_dir="${workspace}/monorepo"
mkdir -p "$mono_dir"

# Read-only preflight: reject malformed input before cloning or creating destination.
declare -a urls=()
declare -a subdirs=()
declare -A seen_subdirs=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%$'\\r'}"
  [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
  read -r url subdir extra <<< "$line"
  [[ -n "$url" && -n "$subdir" && -z "${extra:-}" ]] \\
    || error "Invalid REPOS entry; expected exactly: https://github.com/OWNER/REPO[.git] SUBDIR"
  [[ "$url" =~ ^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\\.git)?$ ]] \\
    || error "Unsupported source URL: only HTTPS github.com repository URLs are accepted"
  [[ "$subdir" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "$subdir" != "." && "$subdir" != *"/../"* && "$subdir" != ../* && "$subdir" != */.. && "$subdir" != *"/./"* ]] \\
    || error "Unsafe destination subdirectory: $subdir"
  [[ -z "${seen_subdirs[$subdir]:-}" ]] || error "Duplicate destination subdirectory: $subdir"
  seen_subdirs[$subdir]=1
  urls+=("$url")
  subdirs+=("$subdir")
done <<< "$REPOS"
[[ ${#urls[@]} -gt 0 ]] || error "REPOS contains no valid source entries"
git check-ref-format --branch "$MONOREPO_BRANCH" >/dev/null 2>&1 \\
  || error "Invalid MONOREPO_BRANCH: $MONOREPO_BRANCH"
python3 -c 'import json,sys; v=json.loads(sys.argv[1]); assert isinstance(v,dict) and all(isinstance(k,str) and isinstance(x,str) for k,x in v.items())' "$BRANCH_MAP" \\
  || error "BRANCH_MAP must be a JSON object of string branch names"
while IFS= read -r branch_name; do
  [[ -z "$branch_name" ]] && continue
  git check-ref-format --branch "$branch_name" >/dev/null 2>&1 \\
    || error "Invalid branch in BRANCH_MAP: $branch_name"
done < <(python3 -c 'import json,sys; print("\\n".join(list(json.loads(sys.argv[1]).keys()) + list(json.loads(sys.argv[1]).values())))' "$BRANCH_MAP")
total=${#urls[@]}
info "Preflight passed for ${total} source repositories."
setup_monorepo "$mono_dir"

info "Merging ${total} repos into monorepo ..."
echo ""

merged=0
failed=0
src_dirs=()
src_subdirs=()
src_urls=()

for (( idx=0; idx<total; idx++ )); do
  url="${urls[$idx]}"
  subdir="${subdirs[$idx]}"
  src_dir="${workspace}/src-${idx}"
  mkdir -p "$src_dir"

  info "── [$(( idx+1 ))/${total}] ${url} → ${subdir}/ ──"

  if ! prepare_source_repo "$url" "$subdir" "$src_dir"; then
    (( failed++ ))
    continue
  fi

  src_dirs+=("$src_dir")
  src_subdirs+=("$subdir")
  src_urls+=("$url")

  if [[ "$NPARENT" != "true" ]]; then
    if sequential_merge "$mono_dir" "$src_dir" "$subdir" "$url"; then
      (( merged++ ))
    else
      (( failed++ ))
    fi
  else
    # In N-parent mode, just collect — merge happens after all repos are prepared
    (( merged++ ))
  fi
  echo ""
done

# N-parent merge (all at once)
if [[ "$NPARENT" == "true" && ${#src_dirs[@]} -gt 0 ]]; then
  if nparent_merge "$mono_dir" "${src_dirs[@]}"; then
    info "N-parent merge complete."
  else
    error "N-parent merge failed; refusing sequential fallback or destination push"
  fi
fi

# Never publish a partial import. Any source failure invalidates this run.
if [[ "$failed" -ne 0 || "$merged" -ne "$total" ]]; then
  error "Import incomplete (merged: ${merged}/${total}, failed: ${failed}); destination was not pushed"
fi

# Fast-forward-only push. Divergence requires operator review; never force-push.
info "Pushing monorepo to GitHub ..."
local_mono_url="${MONOREPO_URL/https:\/\//https://${GH_TOKEN}@}"
git -C "$mono_dir" push "$local_mono_url" \
  "refs/heads/${MONOREPO_BRANCH}:refs/heads/${MONOREPO_BRANCH}" \
  --tags \
  --atomic \
  2>&1 | sanitize \
  || error "Destination push rejected; force-push is prohibited"

echo ""
info "Complete — merged: ${merged} | failed: ${failed}"

# ── Optionally register monorepo in OSP mirror chain ─────────────────────────
if [[ "$MIRROR_MONOREPO" == "true" && "$failed" -eq 0 ]]; then
  info "Dispatching add-mirror-repo for ${MONOREPO_NAME}..."
  _mono_url="https://github.com/${MONOREPO_OWNER}/${MONOREPO_NAME}"
  _dispatch_body=$(printf '{"ref":"main","inputs":{"repo_url":"%s"}}' "$_mono_url")
  _dispatch_http=$(curl -sf -w "%{http_code}" -o /dev/null \
    -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    "${GH_API}/repos/${MONOREPO_OWNER}/fork-sync-all/actions/workflows/add-mirror-repo.yml/dispatches" \
    -d "$_dispatch_body" || echo "000")
  if [[ "$_dispatch_http" == "204" ]]; then
    info "  add-mirror-repo dispatched — monorepo will enter OSP mirror chain."
  else
    warn "  Could not dispatch add-mirror-repo (HTTP ${_dispatch_http}) — register manually."
  fi
fi

budget_report
[[ "$failed" -eq 0 ]] || exit 1
