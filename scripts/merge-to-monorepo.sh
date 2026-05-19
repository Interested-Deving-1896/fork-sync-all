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

GH_API="https://api.github.com"

info()  { echo "[merge-to-monorepo] $*"; }
warn()  { echo "[merge-to-monorepo][warn] $*" >&2; }
error() { echo "[merge-to-monorepo][error] $*" >&2; exit 1; }

sanitize() {
  sed "s/${GH_TOKEN}/***TOKEN***/g" \
  | sed "s/${SOURCE_TOKEN:-NOTOKEN}/***TOKEN***/g"
}

gh_api() {
  curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$@"
}

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
  python3 -c "
import json, sys
m = json.loads('${BRANCH_MAP}')
print(m.get('${src}', '${MONOREPO_BRANCH}'))
" 2>/dev/null || echo "$MONOREPO_BRANCH"
}

# ── Monorepo setup ────────────────────────────────────────────────────────────

setup_monorepo() {
  local mono_dir="$1"

  if [[ -n "$MONOREPO_URL" ]]; then
    info "Cloning existing monorepo: ${MONOREPO_URL} ..."
    local auth_url="${MONOREPO_URL/https:\/\//https://${GH_TOKEN}@}"
    git clone "$auth_url" "$mono_dir" 2>&1 | sanitize
  else
    info "Auto-creating monorepo ${MONOREPO_OWNER}/${MONOREPO_NAME} ..."
    # Create on GitHub if it doesn't exist
    local exists
    exists=$(gh_api "${GH_API}/repos/${MONOREPO_OWNER}/${MONOREPO_NAME}" 2>/dev/null \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")
    if [[ -z "$exists" ]]; then
      gh_api -X POST "${GH_API}/orgs/${MONOREPO_OWNER}/repos" \
        -d "{\"name\":\"${MONOREPO_NAME}\",\"private\":${MONOREPO_PRIVATE},\"auto_init\":true,\"default_branch\":\"${MONOREPO_BRANCH}\"}" \
        > /dev/null || error "Failed to create ${MONOREPO_OWNER}/${MONOREPO_NAME}"
      sleep 3  # let GitHub initialise the repo
    fi
    MONOREPO_URL="https://github.com/${MONOREPO_OWNER}/${MONOREPO_NAME}.git"
    local auth_url="https://${GH_TOKEN}@github.com/${MONOREPO_OWNER}/${MONOREPO_NAME}.git"
    git clone "$auth_url" "$mono_dir" 2>&1 | sanitize
  fi

  # Ensure target branch exists
  if ! git -C "$mono_dir" rev-parse --verify "$MONOREPO_BRANCH" >/dev/null 2>&1; then
    git -C "$mono_dir" checkout -b "$MONOREPO_BRANCH" 2>/dev/null || true
  else
    git -C "$mono_dir" checkout "$MONOREPO_BRANCH" 2>/dev/null || true
  fi

  # Ensure at least one commit exists (needed for merges)
  if ! git -C "$mono_dir" rev-parse HEAD >/dev/null 2>&1; then
    git -C "$mono_dir" commit --allow-empty -m "chore: initialise monorepo" 2>/dev/null || true
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
    git -C "$work_dir" lfs fetch --all 2>/dev/null || true
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
  git -C "$work_dir" filter-repo \
    --to-subdirectory-filter "$subdir" \
    --force \
    2>&1 | tail -3

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
    local remote_name="source-${remote_idx}"
    git -C "$mono_dir" remote add "$remote_name" "$src_dir" 2>/dev/null || true
    git -C "$mono_dir" fetch "$remote_name" --tags 2>/dev/null || true
    local src_head
    src_head=$(git -C "$src_dir" rev-parse HEAD 2>/dev/null || echo "")
    [[ -n "$src_head" ]] && parent_shas+=("$src_head")
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
  GIT_INDEX_FILE="$tmp_index" git -C "$mono_dir" read-tree HEAD 2>/dev/null || true

  local collision_found=false
  for (( i=0; i<${#source_dirs[@]}; i++ )); do
    local src_dir="${source_dirs[$i]}"
    local subdir="${subdirs[$i]}"  # from the global subdirs[] array in main

    local src_tree
    src_tree=$(git -C "$src_dir" rev-parse 'HEAD^{tree}' 2>/dev/null || echo "")
    [[ -z "$src_tree" ]] && continue

    # Check for path collisions before writing: list files in the source tree
    # and see if any already exist in the temp index under the same path.
    # filter-repo has already prefixed everything with <subdir>/, so we check
    # for <subdir>/ entries in the current index.
    local existing_at_subdir
    existing_at_subdir=$(GIT_INDEX_FILE="$tmp_index" git -C "$mono_dir" \
      ls-files --cached -- "${subdir}/" 2>/dev/null | head -1)

    if [[ -n "$existing_at_subdir" ]]; then
      warn "  Path collision: ${subdir}/ already exists in monorepo index."
      warn "  Falling back to sequential merge for this repo."
      collision_found=true
      # Remove this source from parent_shas so it doesn't appear as a parent
      # of the N-parent commit — it will be merged sequentially after.
      unset "parent_shas[$i]"
      continue
    fi

    # No collision — read the source tree into the temp index.
    # --prefix="" is correct here because filter-repo already placed all files
    # under <subdir>/, so the tree's root IS the monorepo root for this source.
    GIT_INDEX_FILE="$tmp_index" git -C "$mono_dir" \
      read-tree --prefix="" -i "$src_tree" 2>/dev/null \
      || { warn "  read-tree failed for ${subdir} — skipping"; continue; }

    info "  Added ${subdir}/ to N-parent tree."
  done

  # Re-index parent_shas (remove gaps from unset)
  local -a valid_parents=()
  for sha in "${parent_shas[@]+"${parent_shas[@]}"}"; do
    valid_parents+=("$sha")
  done

  if [[ ${#valid_parents[@]} -eq 0 && "$collision_found" == "true" ]]; then
    warn "All sources had collisions — falling back entirely to sequential merge"
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

  # If any sources had collisions, merge them sequentially now
  if [[ "$collision_found" == "true" ]]; then
    info "Merging collision sources sequentially ..."
    for (( i=0; i<${#source_dirs[@]}; i++ )); do
      # Only process sources that were skipped (not in valid_parents)
      local src_sha
      src_sha=$(git -C "${source_dirs[$i]}" rev-parse HEAD 2>/dev/null || echo "")
      local found=false
      for p in "${valid_parents[@]}"; do
        [[ "$p" == "$src_sha" ]] && found=true && break
      done
      $found && continue
      sequential_merge "$mono_dir" "${source_dirs[$i]}" "${subdirs[$i]}" "${urls[$i]}"
    done
  fi
}

# ── Sequential merge ──────────────────────────────────────────────────────────

sequential_merge() {
  local mono_dir="$1" src_dir="$2" subdir="$3" url="$4"

  local remote_name
  remote_name="src-$(echo "$subdir" | tr '/' '-')"

  git -C "$mono_dir" remote add "$remote_name" "$src_dir" 2>/dev/null \
    || git -C "$mono_dir" remote set-url "$remote_name" "$src_dir"
  git -C "$mono_dir" fetch "$remote_name" --tags 2>/dev/null || true

  local src_branch
  src_branch=$(detect_default_branch "$src_dir")
  local dest_branch
  dest_branch=$(map_branch "$src_branch")

  # Ensure dest branch exists
  if ! git -C "$mono_dir" rev-parse --verify "$dest_branch" >/dev/null 2>&1; then
    git -C "$mono_dir" checkout -b "$dest_branch" 2>/dev/null || true
  else
    git -C "$mono_dir" checkout "$dest_branch" 2>/dev/null || true
  fi

  info "  Merging ${subdir} (${src_branch} → ${dest_branch}) ..."
  git -C "$mono_dir" merge \
    --allow-unrelated-histories \
    --no-edit \
    -m "chore: merge ${url} into ${subdir}/" \
    "${remote_name}/${src_branch}" \
    2>&1 | tail -5 \
    || { warn "  Merge conflict in ${subdir} — attempting strategy=ours"; \
         git -C "$mono_dir" merge --abort 2>/dev/null || true; \
         git -C "$mono_dir" merge \
           --allow-unrelated-histories \
           --no-edit \
           -s ours \
           -m "chore: merge ${url} into ${subdir}/ (ours strategy)" \
           "${remote_name}/${src_branch}" 2>&1 | tail -3; }

  git -C "$mono_dir" remote remove "$remote_name" 2>/dev/null || true
}

# ── Main ──────────────────────────────────────────────────────────────────────

check_deps

workspace=$(mktemp -d)
trap 'rm -rf "${workspace}"' EXIT

mono_dir="${workspace}/monorepo"
mkdir -p "$mono_dir"

setup_monorepo "$mono_dir"

# Parse REPOS input: each entry is "url subdir" (one per line or space-separated)
declare -a repo_entries=()
while IFS= read -r line; do
  line="${line//  / }"  # normalise multiple spaces
  line="${line#"${line%%[![:space:]]*}"}"  # ltrim
  [[ -z "$line" || "$line" == \#* ]] && continue
  repo_entries+=("$line")
done < <(echo "$REPOS" | tr ' ' '\n' | paste - - 2>/dev/null || echo "$REPOS")

# Re-parse as pairs
declare -a urls=()
declare -a subdirs=()
i=0
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  url=$(echo "$line" | awk '{print $1}')
  subdir=$(echo "$line" | awk '{print $2}')
  [[ -z "$url" || -z "$subdir" ]] && continue
  urls+=("$url")
  subdirs+=("$subdir")
  (( i++ ))
done < <(echo "$REPOS")

total=${#urls[@]}
info "Merging ${total} repos into monorepo ..."
echo ""

merged=0
failed=0
src_dirs=()

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
    warn "N-parent merge failed — falling back to sequential"
    for (( idx=0; idx<${#src_dirs[@]}; idx++ )); do
      sequential_merge "$mono_dir" "${src_dirs[$idx]}" "${subdirs[$idx]}" "${urls[$idx]}" || true
    done
  fi
fi

# Push monorepo to GitHub
info "Pushing monorepo to GitHub ..."
local_mono_url="${MONOREPO_URL/https:\/\//https://${GH_TOKEN}@}"
git -C "$mono_dir" push "$local_mono_url" \
  "refs/heads/${MONOREPO_BRANCH}:refs/heads/${MONOREPO_BRANCH}" \
  --tags \
  --force-with-lease \
  2>&1 | sanitize \
  || git -C "$mono_dir" push "$local_mono_url" \
       "refs/heads/${MONOREPO_BRANCH}:refs/heads/${MONOREPO_BRANCH}" \
       --tags --force \
       2>&1 | sanitize

echo ""
info "Complete — merged: ${merged} | failed: ${failed}"
[[ "$failed" -eq 0 ]] || exit 1
