#!/usr/bin/env bash
#
# Mirrors all Interested-Deving-1896 repos that have a GitLab counterpart
# in openos-project to their respective GitLab projects.
#
# Uses git push --mirror so all branches and tags stay in sync.
# Local-only GitLab branches (all-features, feat/*, lts, openos/*) are
# preserved because --mirror only pushes refs that exist in the source;
# it does not delete refs that don't exist in the source when the GitLab
# project has additional refs not present on GitHub.
#
# Wait — --mirror DOES delete remote refs not in source. To preserve
# GitLab-only branches we use selective push instead:
#   1. Push all refs from GitHub (branches + tags) with force
#   2. Never prune GitLab-only refs
#
# Required CI variables:
#   GH_TOKEN      — GitHub PAT with repo read scope
#   GITLAB_TOKEN  — GitLab PAT with api + write_repository scope
#   GITHUB_OWNER  — GitHub org (Interested-Deving-1896)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"
: "${GITHUB_OWNER:=Interested-Deving-1896}"

DRY_RUN="${DRY_RUN:-false}"
REPO_FILTER="${REPO_FILTER:-}"
FORCE="${FORCE:-false}"   # re-push even if GitLab project already up-to-date

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/branch-name-conv.sh
source "${SCRIPT_DIR}/branch-name-conv.sh"
# shellcheck source=scripts/includes/budget.sh
source "${SCRIPT_DIR}/includes/budget.sh"
# shellcheck source=scripts/includes/platform-adapter.sh
source "${SCRIPT_DIR}/includes/platform-adapter.sh"

# Initialise platform adapter for GitLab destination
PLATFORM=gitlab PLATFORM_TOKEN="$GITLAB_TOKEN" pa_init gitlab

# Helpers must be defined before any call site (including the early log lines below)
info() { echo "[sync-to-gitlab] $*" >&2; }
warn() { echo "[warn] $*" >&2; }

[[ "$DRY_RUN" == "true" ]] && info "Dry run — no pushes will occur."
[[ "$FORCE"   == "true" ]] && info "Force mode — all repos will be re-pushed."
[[ -n "$REPO_FILTER"    ]] && info "Repo filter: '${REPO_FILTER}'"

# ── Repo map: built from config/gitlab-subgroups.yml ─────────────────────────
# Single source of truth — edit config/gitlab-subgroups.yml to add/move repos.
SUBGROUP_CONFIG="${REPO_ROOT}/config/gitlab-subgroups.yml"

mapfile -t REPOS < <(SUBGROUP_CONFIG_PATH="$SUBGROUP_CONFIG" python3 - <<'PYEOF'
import sys, re, os

config_path = os.environ.get("SUBGROUP_CONFIG_PATH", "config/gitlab-subgroups.yml")
try:
    with open(config_path) as f:
        content = f.read()
except FileNotFoundError:
    sys.exit(0)

current_sg = None
current_path = None  # explicit path: field overrides key-derived path
for line in content.splitlines():
    sg_m = re.match(r'^  (\S+):$', line)
    if sg_m:
        current_sg = sg_m.group(1)
        current_path = None  # reset for each new subgroup
        continue
    path_m = re.match(r'^\s+path:\s+(\S+)', line)
    if path_m and current_sg:
        current_path = path_m.group(1)
        continue
    repo_m = re.match(r'^\s+-\s+(\S+)', line)
    if repo_m and current_sg and current_sg not in ('id', 'repos', 'path'):
        repo = repo_m.group(1)
        ns = current_path if current_path else f"openos-project/{current_sg}"
        print(f"{repo}|{ns}/{repo}")
PYEOF
)

# ── git push with retry ───────────────────────────────────────────────────────
# GitLab enforces per-project push rate limits and occasionally returns
# transient errors under load. Retry up to 3 times with exponential backoff.
# Note: this is a git-level retry, not an HTTP API retry — the exit code from
# `git push` is non-zero on any remote rejection, including rate limiting.
git_push_with_retry() {
  local remote="$1"; shift
  local refspecs=("$@") max_retries=3 attempt=0
  while true; do
    if git push "$remote" "${refspecs[@]}" 2>&1 \
        | sed "s/${GH_TOKEN}/***TOKEN***/g" \
        | sed "s/${GITLAB_TOKEN}/***TOKEN***/g"; then
      return 0
    fi
    (( attempt++ )) || true
    if (( attempt > max_retries )); then
      warn "Push failed after ${max_retries} attempts"
      return 1
    fi
    local wait=$(( attempt * 15 ))
    warn "[push-retry] attempt ${attempt}/${max_retries} failed — retrying in ${wait}s"
    sleep "$wait"
  done
}

synced=0
failed=0
skipped=0

budget_init

for entry in "${REPOS[@]}"; do
  gh_repo="${entry%%|*}"
  gl_path="${entry##*|}"
  budget_check "$gh_repo" || break

  # Apply repo name substring filter
  if [[ -n "$REPO_FILTER" && "$gh_repo" != *"$REPO_FILTER"* ]]; then
    continue
  fi

  info "──────────────────────────────────────────"
  info "${GITHUB_OWNER}/${gh_repo}  →  gitlab.com/${gl_path}"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "  DRY  would push ${gh_repo}"
    (( synced++ )) || true
    continue
  fi

  # Use platform-adapter for authenticated URLs — avoids hardcoded token embedding.
  PLATFORM=github PLATFORM_TOKEN="$GH_TOKEN" pa_init github 2>/dev/null
  gh_url=$(pa_clone_url "$GITHUB_OWNER" "$gh_repo")
  PLATFORM=gitlab PLATFORM_TOKEN="$GITLAB_TOKEN" pa_init gitlab 2>/dev/null
  gl_url=$(pa_push_url "$(dirname "$gl_path")" "$(basename "$gl_path")")

  work_dir=$(mktemp -d)

  # Clone a bare mirror from GitHub
  if ! git clone --mirror "$gh_url" "$work_dir" 2>&1 \
      | sed "s/${GH_TOKEN}/***TOKEN***/g"; then
    warn "Clone failed for ${GITHUB_OWNER}/${gh_repo} — skipping"
    rm -rf "$work_dir"
    failed=$((failed + 1))
    continue
  fi

  cd "$work_dir" || exit 1

  # Push branches to GitLab with platform-safe name encoding.
  # branch-name-conv.sh encodes names that would be rejected by stricter
  # platforms (e.g. GitLab rejects depth≥2 names ending in YYYY-MM-DD).
  # GitLab-only branches (all-features, feat/*, lts, openos/ci, etc.) are
  # untouched because we never push a delete instruction for them.
  push_ok=true
  storage_limit=false
  attempt=0
  max_retries=3
  while true; do
    push_output=$(push_branches_encoded "$gl_url" 2>&1 \
        | sed "s/${GITLAB_TOKEN}/***TOKEN***/g" \
        | sed "s/${GH_TOKEN}/***TOKEN***/g")
    push_exit=${PIPESTATUS[0]}
    echo "$push_output"
    # Detect GitLab free-tier storage limit — retrying won't help
    if echo "$push_output" | grep -q "free storage limit"; then
      warn "GitLab storage limit reached for ${gh_repo} — skipping (not a code error)"
      storage_limit=true
      push_ok=false
      break
    fi
    [[ $push_exit -eq 0 ]] && break
    (( attempt++ )) || true
    if (( attempt > max_retries )); then
      warn "Branch push failed after ${max_retries} attempts"
      push_ok=false
      break
    fi
    wait=$(( attempt * 15 ))
    warn "[push-retry] attempt ${attempt}/${max_retries} failed — retrying in ${wait}s"
    sleep "$wait"
  done

  git push "$gl_url" '+refs/tags/*:refs/tags/*' 2>&1 \
    | sed "s/${GITLAB_TOKEN}/***TOKEN***/g" || true  # tag failures are non-fatal

  cd /
  rm -rf "$work_dir"

  if $push_ok; then
    info "✅ ${gh_repo} done"
    synced=$((synced + 1))
  elif $storage_limit; then
    warn "⚠ ${gh_repo} skipped — GitLab storage limit"
    skipped=$((skipped + 1))
  else
    warn "✗ ${gh_repo} push failed"
    failed=$((failed + 1))
  fi
done

echo ""
info "Complete — synced: ${synced} | skipped: ${skipped} | failed: ${failed}"
budget_report
[ "$failed" -eq 0 ] || exit 1
