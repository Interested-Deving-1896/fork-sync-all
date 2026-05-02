#!/usr/bin/env bash
#
# Mirrors every repo in OSP_ORG (OpenOS-Project-OSP) to its GitLab counterpart
# under openos-project, creating the GitLab project if it doesn't exist yet.
#
# Repo → subgroup placement follows the same taxonomy used when the GitLab
# projects were originally created:
#
#   penguins-eggs, penguins-recovery, penguins-eggs-book, penguins-eggs-audit,
#   penguins-powerwash, penguins-immutable-framework, penguins-incus-platform,
#   penguins-kernel-manager, eggs-ai, eggs-gui, oa-tools
#     → penguins-eggs_deving  (130516402)
#
#   immutable-linux-framework
#     → immutable-filesystem_deving  (130516465)
#
#   liqxanmod, lkm, ukm, lkf, liquorix-unified-kernel, xanmod-unified-kernel,
#   btrfs-dwarfs-framework, linux-powerwash
#     → linux-kernel_filesystem_deving  (130516188)
#
#   incus-image-server, kapsule-incus-manager, incusbox, Incus-MacOS-Toolkit,
#   incus-windows-toolkit, talos, talos-incus, waydroid-toolkit
#     → incus_deving  (130516536)
#
#   flatpak-repo, org-mirror, btrfs-dwarfs-framework (already above)
#     → ops  (130734009)  for fork-sync-all; others → incus_deving fallback
#
#   fork-sync-all
#     → ops  (130734009)
#
# Any repo not in the explicit map falls back to ops (130734009).
#
# Push strategy: bare-clone from GitHub, push +refs/heads/* +refs/tags/* to
# GitLab. GitLab-only branches (all-features, openos/ci, feat/*, lts) are
# never deleted because we don't use --mirror prune.
#
# Required env vars:
#   GH_TOKEN      — GitHub PAT with repo read scope
#   GITLAB_TOKEN  — GitLab PAT with api + write_repository scope on openos-project
#   OSP_ORG       — GitHub org to mirror from (OpenOS-Project-OSP)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OSP_ORG:=OpenOS-Project-OSP}"

# GITLAB_TOKEN is required but may be absent while the GitLab account is
# pending reinstatement. Exit 0 (skip) rather than 1 (failure) so the
# workflow does not generate CI failure notifications in the interim.
if [ -z "${GITLAB_TOKEN:-}" ]; then
  echo "[mirror-osp-to-gitlab] GITLAB_TOKEN is not set — skipping."
  echo "  Set it with: gh secret set GITLAB_SYNC_TOKEN --repo OpenOS-Project-OSP/fork-sync-all"
  exit 0
fi

GL_API="https://gitlab.com/api/v4"
GH_API="https://api.github.com"

# ── Subgroup map: repo_name → GitLab namespace_id ────────────────────────────
declare -A SUBGROUP_MAP
# penguins-eggs_deving (130516402)
for r in penguins-eggs penguins-recovery penguins-eggs-book penguins-eggs-audit \
          penguins-powerwash penguins-immutable-framework penguins-incus-platform \
          penguins-kernel-manager eggs-ai eggs-gui oa-tools; do
  SUBGROUP_MAP["$r"]=130516402
done
# immutable-filesystem_deving (130516465)
SUBGROUP_MAP["immutable-linux-framework"]=130516465
# linux-kernel_filesystem_deving (130516188)
for r in liqxanmod lkm ukm lkf liquorix-unified-kernel xanmod-unified-kernel \
          btrfs-dwarfs-framework linux-powerwash; do
  SUBGROUP_MAP["$r"]=130516188
done
# incus_deving (130516536)
for r in incus-image-server kapsule-incus-manager incusbox Incus-MacOS-Toolkit \
          incus-windows-toolkit talos talos-incus waydroid-toolkit; do
  SUBGROUP_MAP["$r"]=130516536
done
# ops (130734009)
for r in fork-sync-all flatpak-repo org-mirror; do
  SUBGROUP_MAP["$r"]=130734009
done

DEFAULT_SUBGROUP=130734009   # ops — fallback for unmapped repos

# Repos to skip entirely (no GitLab mirror needed)
EXCLUDED_REPOS=()

info() { echo "[mirror-osp-to-gitlab] $*"; }
warn() { echo "[warn] $*" >&2; }

is_excluded() {
  local name="$1"
  for ex in "${EXCLUDED_REPOS[@]+"${EXCLUDED_REPOS[@]}"}"; do
    [[ "$name" == "$ex" ]] && return 0
  done
  return 1
}

# Returns the GitLab project HTTP URL if it exists, empty string if not
gl_project_url() {
  local namespace_path="$1"
  local encoded
  encoded=$(printf '%s' "$namespace_path" | sed 's|/|%2F|g')
  local result http_code
  result=$(curl -sf -w "\n%{http_code}" \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${GL_API}/projects/${encoded}" 2>/dev/null) || true
  http_code=$(echo "$result" | tail -1)
  if [[ "$http_code" == "200" ]]; then
    echo "$result" | sed '$d' | grep -o '"http_url_to_repo":"[^"]*"' | sed 's/"http_url_to_repo":"//;s/"//'
  fi
}

# Creates a GitLab project under the given namespace_id, returns HTTP URL
gl_create_project() {
  local name="$1" namespace_id="$2"
  info "  Creating GitLab project '${name}' in namespace ${namespace_id} ..."
  local result
  result=$(curl -sf \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "{\"name\":\"${name}\",\"path\":\"${name}\",\"namespace_id\":${namespace_id},\"visibility\":\"public\",\"initialize_with_readme\":false}" \
    "${GL_API}/projects" 2>/dev/null) || true
  echo "$result" | grep -o '"http_url_to_repo":"[^"]*"' | sed 's/"http_url_to_repo":"//;s/"//'
}

get_osp_repos() {
  local page=1
  while true; do
    local result count
    result=$(curl -sf \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${GH_API}/orgs/${OSP_ORG}/repos?type=all&per_page=100&page=${page}") || break
    count=$(echo "$result" | grep -o '"id"' | wc -l)
    [[ "$count" -eq 0 ]] && break
    echo "$result" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//'
    (( page++ ))
  done
}

mirror_repo() {
  local gh_name="$1" gl_url="$2"

  local gh_clone_url="https://x-access-token:${GH_TOKEN}@github.com/${OSP_ORG}/${gh_name}.git"
  local gl_auth_url="${gl_url/https:\/\//https://oauth2:${GITLAB_TOKEN}@}"

  local work_dir
  work_dir=$(mktemp -d)

  info "  Cloning github.com/${OSP_ORG}/${gh_name} ..."
  if ! git clone --mirror "$gh_clone_url" "$work_dir" 2>&1 \
       | sed "s/${GH_TOKEN}/***TOKEN***/g"; then
    warn "  Clone failed"
    rm -rf "$work_dir"
    return 1
  fi

  cd "$work_dir"

  local push_ok=true

  git push "$gl_auth_url" '+refs/heads/*:refs/heads/*' 2>&1 \
    | sed "s/${GITLAB_TOKEN}/***TOKEN***/g" \
    || push_ok=false

  git push "$gl_auth_url" '+refs/tags/*:refs/tags/*' 2>&1 \
    | sed "s/${GITLAB_TOKEN}/***TOKEN***/g" \
    || true   # tag failures non-fatal

  cd /
  rm -rf "$work_dir"

  $push_ok
}

# ── main ─────────────────────────────────────────────────────────────────────

synced=0
failed=0
skipped=0

info "Fetching repos from ${OSP_ORG} ..."
mapfile -t osp_repos < <(get_osp_repos)
info "Found ${#osp_repos[@]} repos."
echo ""

for name in "${osp_repos[@]}"; do
  [[ -z "$name" ]] && continue

  if is_excluded "$name"; then
    (( skipped++ )) || true
    continue
  fi

  # Determine target subgroup
  namespace_id="${SUBGROUP_MAP[$name]:-$DEFAULT_SUBGROUP}"

  # Derive the GitLab namespace path from the subgroup ID
  case "$namespace_id" in
    130516402) ns_path="openos-project/penguins-eggs_deving/${name}" ;;
    130516465) ns_path="openos-project/immutable-filesystem_deving/${name}" ;;
    130516188) ns_path="openos-project/linux-kernel_filesystem_deving/${name}" ;;
    130516536) ns_path="openos-project/incus_deving/${name}" ;;
    130734009) ns_path="openos-project/ops/${name}" ;;
    *)         ns_path="openos-project/ops/${name}" ;;
  esac

  info "──────────────────────────────────────────"
  info "github.com/${OSP_ORG}/${name}  →  gitlab.com/${ns_path}"

  # Check if GitLab project exists; create if not
  gl_http_url=$(gl_project_url "$ns_path")
  if [[ -z "$gl_http_url" ]]; then
    gl_http_url=$(gl_create_project "$name" "$namespace_id")
    if [[ -z "$gl_http_url" ]]; then
      warn "  Could not create GitLab project — skipping"
      (( failed++ )) || true
      continue
    fi
    info "  Created: ${gl_http_url}"
    # Brief pause to let GitLab finish initialising the repo
    sleep 3
  fi

  if mirror_repo "$name" "$gl_http_url"; then
    info "✅ ${name} done"
    (( synced++ )) || true
  else
    warn "❌ ${name} failed"
    (( failed++ )) || true
  fi
done

echo ""
info "Complete — synced: ${synced} | skipped: ${skipped} | failed: ${failed}"
[ "$failed" -eq 0 ] || exit 1
