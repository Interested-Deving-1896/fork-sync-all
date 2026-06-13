#!/usr/bin/env bash
# org-storage-maintenance.sh — org-wide storage housekeeping.
#
# Runs across all actively developed projects under openos-project,
# excluding upstream mirror groups (kde-ecosystem-deving, upstream-mirrors,
# chromium_browser-os_deving) which have no CI artifacts or LFS of our own.
#
# Actions per project:
#   1. Trigger bulk artifact expiry (forces immediate deletion of expired artifacts)
#   2. Delete generic package versions older than PACKAGE_MAX_AGE_DAYS,
#      keeping at least PACKAGE_KEEP_COUNT per package name
#
# LFS prune is intentionally NOT done here org-wide — it requires a full
# git clone of each repo and is too slow at org scale. It runs per-project
# via each project's own scheduled-maintenance.yml pipeline.
#
# Required env vars:
#   GITLAB_MAINTENANCE_TOKEN  — PAT with api scope (inherited from group variable)
#   CI_API_V4_URL             — set automatically by GitLab CI
#
# Optional env vars (override defaults):
#   PACKAGE_MAX_AGE_DAYS      — delete package versions older than this (default: 90)
#   PACKAGE_KEEP_COUNT        — always keep this many recent versions (default: 5)
#   DRY_RUN                   — set to "true" to log actions without executing them

set -euo pipefail

GITLAB_TOKEN="${GITLAB_MAINTENANCE_TOKEN}"
API="${CI_API_V4_URL}"
PACKAGE_MAX_AGE_DAYS="${PACKAGE_MAX_AGE_DAYS:-90}"
PACKAGE_KEEP_COUNT="${PACKAGE_KEEP_COUNT:-5}"
DRY_RUN="${DRY_RUN:-false}"

# Groups to process — actively developed, not upstream mirrors
ACTIVE_GROUPS=(
  "openos-project/ops"
  "openos-project/git-management_deving"
  "openos-project/incus_deving"
  "openos-project/ipfs-deving"
  "openos-project/immutable-filesystem_deving"
  "openos-project/penguins-eggs_deving"
  "openos-project/linux-distro_feature-modules_deving"
  "openos-project/linux-kernel_filesystem_deving"
  "openos-project/cloud-deving"
  "openos-project/freebsd-deving"
)

# ── Helpers ───────────────────────────────────────────────────────────────────

info()  { echo "[INFO]  $*" >&2; }
warn()  { echo "[WARN]  $*" >&2; }
dry()   { echo "[DRY]   $*" >&2; }

api_get() {
  curl -sf \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "$@"
}

api_post() {
  local url="$1"; shift
  if [ "${DRY_RUN}" = "true" ]; then
    dry "POST ${url}"
    return 0
  fi
  curl -sf -X POST \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${url}" "$@" -o /dev/null || warn "POST ${url} failed"
}

api_delete() {
  local url="$1"
  if [ "${DRY_RUN}" = "true" ]; then
    dry "DELETE ${url}"
    return 0
  fi
  curl -sf -X DELETE \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${url}" -o /dev/null || warn "DELETE ${url} failed"
}

encode() {
  printf '%s' "$1" | sed 's|/|%2F|g'
}

# ── Per-project actions ───────────────────────────────────────────────────────

expire_artifacts() {
  local project_id="$1" project_path="$2"
  info "  Expiring artifacts for ${project_path}..."
  api_post "${API}/projects/${project_id}/artifacts" || true
}

cleanup_packages() {
  local project_id="$1" project_path="$2"

  # Cutoff date — BSD and GNU date compatible
  local cutoff
  cutoff=$(date -u -d "${PACKAGE_MAX_AGE_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
           || date -u -v-${PACKAGE_MAX_AGE_DAYS}d +%Y-%m-%dT%H:%M:%SZ)

  # Get distinct package names
  local pkg_names
  pkg_names=$(api_get \
    "${API}/projects/${project_id}/packages?per_page=100&order_by=name" \
    | jq -r '.[].name' 2>/dev/null | sort -u) || return 0

  [ -z "${pkg_names}" ] && return 0

  while IFS= read -r pkg_name; do
    local versions
    versions=$(api_get \
      "${API}/projects/${project_id}/packages?package_name=$(printf '%s' "${pkg_name}" | jq -sRr @uri)&order_by=created_at&sort=desc&per_page=100" \
      | jq -r '.[] | "\(.id) \(.created_at)"' 2>/dev/null) || continue

    [ -z "${versions}" ] && continue

    local count=0
    while IFS= read -r line; do
      count=$((count + 1))
      local pkg_id pkg_date
      pkg_id=$(echo "${line}" | awk '{print $1}')
      pkg_date=$(echo "${line}" | awk '{print $2}')

      if [ "${count}" -le "${PACKAGE_KEEP_COUNT}" ]; then
        continue  # always keep the N most recent
      fi

      if [[ "${pkg_date}" < "${cutoff}" ]]; then
        info "  Deleting package ${pkg_name}@${pkg_id} (${pkg_date}) from ${project_path}"
        api_delete "${API}/projects/${project_id}/packages/${pkg_id}"
      fi
    done <<< "${versions}"
  done <<< "${pkg_names}"
}

process_project() {
  local project_id="$1" project_path="$2"
  info "Processing: ${project_path} (id=${project_id})"
  expire_artifacts "${project_id}" "${project_path}"
  cleanup_packages "${project_id}" "${project_path}"
}

# ── Collect projects ──────────────────────────────────────────────────────────

collect_projects() {
  local group="$1"
  local encoded
  encoded=$(encode "${group}")

  local page=1
  while true; do
    local batch
    batch=$(api_get \
      "${API}/groups/${encoded}/projects?include_subgroups=true&per_page=100&page=${page}&archived=false" \
      | jq -r '.[] | "\(.id) \(.path_with_namespace)"' 2>/dev/null) || break

    [ -z "${batch}" ] && break

    echo "${batch}"

    local count
    count=$(echo "${batch}" | wc -l)
    [ "${count}" -lt 100 ] && break
    page=$((page + 1))
  done
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  info "=== Org-wide storage maintenance ==="
  info "DRY_RUN=${DRY_RUN}"
  info "PACKAGE_MAX_AGE_DAYS=${PACKAGE_MAX_AGE_DAYS}"
  info "PACKAGE_KEEP_COUNT=${PACKAGE_KEEP_COUNT}"
  info ""

  local total=0 processed=0

  for group in "${ACTIVE_GROUPS[@]}"; do
    info "--- Group: ${group} ---"
    local projects
    projects=$(collect_projects "${group}")

    [ -z "${projects}" ] && { info "  No projects found"; continue; }

    while IFS= read -r line; do
      [ -z "${line}" ] && continue
      local project_id project_path
      project_id=$(echo "${line}" | awk '{print $1}')
      project_path=$(echo "${line}" | awk '{print $2}')
      total=$((total + 1))
      process_project "${project_id}" "${project_path}"
      processed=$((processed + 1))
    done <<< "${projects}"
  done

  info ""
  info "=== Complete: processed ${processed}/${total} projects ==="
}

main "$@"
