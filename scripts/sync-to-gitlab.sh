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

GL_HOST="https://gitlab.com"

info() { echo "[sync-to-gitlab] $*"; }
warn() { echo "[warn] $*" >&2; }

# ── Repo map: "github_repo|gitlab_path_with_namespace" ───────────────────────
# gitlab_path_with_namespace is the full path under gitlab.com/
REPOS=(
  # Penguins-Eggs_Deving
  "penguins-eggs|openos-project/penguins-eggs_deving/penguins-eggs"
  "penguins-recovery|openos-project/penguins-eggs_deving/penguins-recovery"
  "penguins-eggs-book|openos-project/penguins-eggs_deving/penguins-eggs-book"
  "penguins-eggs-audit|openos-project/penguins-eggs_deving/penguins-eggs-audit"
  "penguins-powerwash|openos-project/penguins-eggs_deving/penguins-powerwash"
  "penguins-immutable-framework|openos-project/penguins-eggs_deving/penguins-immutable-framework"
  "penguins-incus-platform|openos-project/penguins-eggs_deving/penguins-incus-platform"
  "penguins-kernel-manager|openos-project/penguins-eggs_deving/penguins-kernel-manager"
  "eggs-ai|openos-project/penguins-eggs_deving/eggs-ai"
  "eggs-gui|openos-project/penguins-eggs_deving/eggs-gui"
  "oa-tools|openos-project/penguins-eggs_deving/oa-tools"
  # Immutable-Filesystem_Deving
  "immutable-linux-framework|openos-project/immutable-filesystem_deving/immutable-linux-framework"
  # Linux-Kernel_Filesystem_Deving
  "liqxanmod|openos-project/linux-kernel_filesystem_deving/liqxanmod"
  "lkm|openos-project/linux-kernel_filesystem_deving/lkm"
  "ukm|openos-project/linux-kernel_filesystem_deving/ukm"
  "lkf|openos-project/linux-kernel_filesystem_deving/lkf"
  "liquorix-unified-kernel|openos-project/linux-kernel_filesystem_deving/liquorix-unified-kernel"
  "xanmod-unified-kernel|openos-project/linux-kernel_filesystem_deving/xanmod-unified-kernel"
  "btrfs-dwarfs-framework|openos-project/linux-kernel_filesystem_deving/btrfs-dwarfs-framework"
  # ops
  "fork-sync-all|openos-project/ops/fork-sync-all"
)

synced=0
failed=0

for entry in "${REPOS[@]}"; do
  gh_repo="${entry%%|*}"
  gl_path="${entry##*|}"

  info "──────────────────────────────────────────"
  info "${GITHUB_OWNER}/${gh_repo}  →  gitlab.com/${gl_path}"

  gh_url="https://${GH_TOKEN}@github.com/${GITHUB_OWNER}/${gh_repo}.git"
  gl_url="${GL_HOST/https:\/\//https://oauth2:${GITLAB_TOKEN}@}/${gl_path}.git"

  work_dir=$(mktemp -d)

  # Clone a bare mirror from GitHub
  if ! git clone --mirror "$gh_url" "$work_dir" 2>&1; then
    warn "Clone failed for ${GITHUB_OWNER}/${gh_repo} — skipping"
    rm -rf "$work_dir"
    failed=$((failed + 1))
    continue
  fi

  cd "$work_dir"

  # Fetch all refs (branches + tags) from GitHub into the bare clone
  # (already done by --mirror clone, but refresh in case of retries)

  # Push all refs to GitLab without pruning GitLab-only refs.
  # +refs/heads/*:refs/heads/* force-updates all GitHub branches.
  # +refs/tags/*:refs/tags/*   force-updates all GitHub tags.
  # GitLab-only branches (all-features, feat/*, lts, openos/ci, etc.)
  # are untouched because we never push a delete instruction for them.
  push_ok=true

  git push "$gl_url" '+refs/heads/*:refs/heads/*' 2>&1 || push_ok=false
  git push "$gl_url" '+refs/tags/*:refs/tags/*'   2>&1 || true  # tag failures are non-fatal

  cd /
  rm -rf "$work_dir"

  if $push_ok; then
    info "✅ ${gh_repo} done"
    synced=$((synced + 1))
  else
    warn "Push failed for ${gh_repo}"
    failed=$((failed + 1))
  fi
done

echo ""
info "Complete — synced: ${synced} | failed: ${failed}"
[ "$failed" -eq 0 ] || exit 1
