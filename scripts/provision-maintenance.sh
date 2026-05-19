#!/usr/bin/env bash
# provision-maintenance.sh — push .gitlab/scheduled-maintenance.yml and
# create a weekly maintenance schedule on every actively developed project
# under openos-project.
#
# Safe to re-run — skips projects that already have the file and schedule.
#
# Required env vars:
#   GITLAB_MAINTENANCE_TOKEN  — PAT with api scope
#   CI_API_V4_URL             — set automatically in CI, or export manually
#
# Usage (local):
#   export GITLAB_MAINTENANCE_TOKEN=glpat-...
#   export CI_API_V4_URL=https://gitlab.com/api/v4
#   bash scripts/provision-maintenance.sh
#
# Usage (CI): triggered by the "Provision maintenance" manual job.

set -euo pipefail

TOKEN="${GITLAB_MAINTENANCE_TOKEN}"
API="${CI_API_V4_URL:-https://gitlab.com/api/v4}"
DRY_RUN="${DRY_RUN:-false}"

# Active groups — excludes upstream mirror groups
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

# Stagger schedules across Sunday to avoid all projects hitting the API
# simultaneously. Starts at 04:00 UTC, increments by 10 minutes per project.
SCHEDULE_BASE_HOUR=4
SCHEDULE_BASE_MIN=0
SCHEDULE_COUNTER=0

# ── Helpers ───────────────────────────────────────────────────────────────────

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
skip()  { echo "[SKIP]  $*"; }
dry()   { echo "[DRY]   $*"; }

encode() { printf '%s' "$1" | sed 's|/|%2F|g'; }

next_cron() {
  # Returns a cron expression staggered 10 min apart, wrapping hours
  local total_min=$(( SCHEDULE_BASE_HOUR * 60 + SCHEDULE_BASE_MIN + SCHEDULE_COUNTER * 10 ))
  local hour=$(( total_min / 60 % 24 ))
  local min=$(( total_min % 60 ))
  SCHEDULE_COUNTER=$(( SCHEDULE_COUNTER + 1 ))
  printf '%d %d * * 0' "${min}" "${hour}"
}

api_get() {
  curl -sf -H "PRIVATE-TOKEN: ${TOKEN}" "$@"
}

api_post() {
  local url="$1"; shift
  if [ "${DRY_RUN}" = "true" ]; then dry "POST ${url} $*"; return 0; fi
  curl -sf -X POST -H "PRIVATE-TOKEN: ${TOKEN}" -H "Content-Type: application/json" \
    "${url}" "$@" 2>/dev/null
}

api_put() {
  local url="$1"; shift
  if [ "${DRY_RUN}" = "true" ]; then dry "PUT ${url} $*"; return 0; fi
  curl -sf -X PUT -H "PRIVATE-TOKEN: ${TOKEN}" -H "Content-Type: application/json" \
    "${url}" "$@" 2>/dev/null
}

# ── File content (base64-encoded) ─────────────────────────────────────────────
# This is the .gitlab/scheduled-maintenance.yml pushed to each project.
# It is the same file as in gitlab-enhanced — LFS prune + artifact expiry
# + package cleanup + storage report, activated by MAINTENANCE=true.

MAINTENANCE_YML_B64=$(base64 << 'ENDOFFILE'
# Scheduled maintenance pipeline.
#
# Activated by a GitLab scheduled pipeline with MAINTENANCE=true.
# GITLAB_MAINTENANCE_TOKEN is inherited from the openos-project group variable.
#
# Jobs:
#   lfs:prune        — removes unreferenced LFS objects
#   artifacts:expire — forces bulk expiry of expired artifacts
#   packages:cleanup — deletes package versions older than 90 days (keeps 5)
#   storage:report   — prints storage breakdown

workflow:
  rules:
    - if: $MAINTENANCE == "true"

stages:
  - prune
  - report

lfs:prune:
  stage: prune
  image: alpine:3.19
  before_script:
    - apk add --no-cache git git-lfs
    - git lfs install
  script:
    - |
      echo "LFS objects before prune:"
      git lfs ls-files --all | wc -l || true
      git lfs prune --verify-remote --verbose 2>&1 || true
      echo "LFS prune complete"
  rules:
    - if: $MAINTENANCE == "true"

artifacts:expire:
  stage: prune
  image: alpine:3.19
  before_script:
    - apk add --no-cache curl jq
  script:
    - |
      echo "Triggering bulk artifact expiry..."
      HTTP=$(curl -s -o /tmp/expire-resp.json -w "%{http_code}" \
        -X POST \
        -H "PRIVATE-TOKEN: ${GITLAB_MAINTENANCE_TOKEN}" \
        "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/artifacts")
      if [ "${HTTP}" = "200" ] || [ "${HTTP}" = "202" ]; then
        echo "Artifact expiry triggered (HTTP ${HTTP})"
      else
        echo "WARNING: HTTP ${HTTP}"
        cat /tmp/expire-resp.json
      fi
  rules:
    - if: $MAINTENANCE == "true"

packages:cleanup:
  stage: prune
  image: alpine:3.19
  before_script:
    - apk add --no-cache curl jq
  script:
    - |
      set -euo pipefail
      KEEP=5
      CUTOFF=$(date -u -d "90 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
               || date -u -v-90d +%Y-%m-%dT%H:%M:%SZ)
      PACKAGES=$(curl -sf \
        -H "PRIVATE-TOKEN: ${GITLAB_MAINTENANCE_TOKEN}" \
        "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages?per_page=100" \
        | jq -r '.[].name' | sort -u) || exit 0
      [ -z "${PACKAGES}" ] && echo "No packages found" && exit 0
      for PKG in ${PACKAGES}; do
        VERSIONS=$(curl -sf \
          -H "PRIVATE-TOKEN: ${GITLAB_MAINTENANCE_TOKEN}" \
          "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages?package_name=${PKG}&order_by=created_at&sort=desc&per_page=100" \
          | jq -r '.[] | "\(.id) \(.created_at)"') || continue
        COUNT=0
        while IFS= read -r line; do
          COUNT=$((COUNT+1))
          PKG_ID=$(echo "${line}" | awk '{print $1}')
          PKG_DATE=$(echo "${line}" | awk '{print $2}')
          [ "${COUNT}" -le "${KEEP}" ] && continue
          if [[ "${PKG_DATE}" < "${CUTOFF}" ]]; then
            echo "Deleting ${PKG}@${PKG_ID} (${PKG_DATE})"
            curl -sf -X DELETE \
              -H "PRIVATE-TOKEN: ${GITLAB_MAINTENANCE_TOKEN}" \
              "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages/${PKG_ID}" \
              -o /dev/null
          fi
        done <<< "${VERSIONS}"
      done
  rules:
    - if: $MAINTENANCE == "true"

storage:report:
  stage: report
  image: alpine:3.19
  before_script:
    - apk add --no-cache curl jq
  script:
    - |
      echo "=== Storage report: ${CI_PROJECT_PATH} ==="
      curl -sf \
        -H "PRIVATE-TOKEN: ${GITLAB_MAINTENANCE_TOKEN}" \
        "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}" \
        | jq '{statistics: .statistics | {storage_size,lfs_objects_size,job_artifacts_size,packages_size,repository_size}}' \
        || echo "Statistics unavailable"
  rules:
    - if: $MAINTENANCE == "true"
ENDOFFILE
)

# ── Per-project provisioning ──────────────────────────────────────────────────

provision_project() {
  local project_id="$1" project_path="$2" default_branch="$3"

  # Skip if project is archived or empty
  [ -z "${default_branch}" ] && { skip "${project_path} — no default branch (empty/archived)"; return; }

  # 1. Push .gitlab/scheduled-maintenance.yml if not already present
  local file_url="${API}/projects/${project_id}/repository/files/.gitlab%2Fscheduled-maintenance.yml"
  local exists
  exists=$(curl -sf -o /dev/null -w "%{http_code}" \
    -H "PRIVATE-TOKEN: ${TOKEN}" \
    "${file_url}?ref=${default_branch}" 2>/dev/null || echo "000")

  if [ "${exists}" = "200" ]; then
    skip "${project_path} — .gitlab/scheduled-maintenance.yml already exists"
  else
    info "${project_path} — pushing .gitlab/scheduled-maintenance.yml"
    if [ "${DRY_RUN}" != "true" ]; then
      HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "PRIVATE-TOKEN: ${TOKEN}" \
        -H "Content-Type: application/json" \
        "${file_url}" \
        -d "{
          \"branch\": \"${default_branch}\",
          \"content\": $(echo "${MAINTENANCE_YML_B64}" | base64 -d | jq -Rs .),
          \"commit_message\": \"ci: add scheduled maintenance pipeline\",
          \"author_name\": \"openos-ci\",
          \"author_email\": \"ci@openos.dev\"
        }" 2>/dev/null)
      if [ "${HTTP}" = "201" ]; then
        info "${project_path} — file pushed (HTTP ${HTTP})"
      else
        warn "${project_path} — file push failed (HTTP ${HTTP})"
      fi
    fi
  fi

  # 2. Create schedule if none exists with description "Weekly maintenance"
  local schedules
  schedules=$(api_get "${API}/projects/${project_id}/pipeline_schedules" \
    | jq -r '.[] | .description' 2>/dev/null || echo "")

  if echo "${schedules}" | grep -q "Weekly maintenance"; then
    skip "${project_path} — schedule already exists"
  else
    local cron
    cron=$(next_cron)
    info "${project_path} — creating schedule (${cron})"
    local sched_id
    sched_id=$(api_post "${API}/projects/${project_id}/pipeline_schedules" \
      -d "{\"description\":\"Weekly maintenance\",\"ref\":\"${default_branch}\",\"cron\":\"${cron}\",\"cron_timezone\":\"UTC\",\"active\":false}" \
      | jq -r '.id' 2>/dev/null || echo "")

    if [ -n "${sched_id}" ] && [ "${sched_id}" != "null" ]; then
      # Add MAINTENANCE=true variable to the schedule
      api_post "${API}/projects/${project_id}/pipeline_schedules/${sched_id}/variables" \
        -d '{"key":"MAINTENANCE","value":"true"}' > /dev/null 2>&1 || true
      info "${project_path} — schedule created (id=${sched_id}, inactive until token is set)"
    else
      warn "${project_path} — schedule creation failed (may have hit 10-schedule limit)"
    fi
  fi
}

collect_projects() {
  local group="$1"
  local encoded
  encoded=$(encode "${group}")
  local page=1
  while true; do
    local batch
    batch=$(api_get \
      "${API}/groups/${encoded}/projects?include_subgroups=true&per_page=100&page=${page}&archived=false" \
      | jq -r '.[] | "\(.id) \(.path_with_namespace) \(.default_branch // "")"' 2>/dev/null) || break
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
  info "=== Provisioning maintenance pipelines ==="
  info "DRY_RUN=${DRY_RUN}"
  info ""

  # shellcheck disable=SC2034
  local total=0 provisioned=0 skipped=0

  for group in "${ACTIVE_GROUPS[@]}"; do
    info "--- Group: ${group} ---"
    local projects
    projects=$(collect_projects "${group}")
    [ -z "${projects}" ] && { info "  No projects"; continue; }

    while IFS= read -r line; do
      [ -z "${line}" ] && continue
      local project_id project_path default_branch
      project_id=$(echo "${line}" | awk '{print $1}')
      project_path=$(echo "${line}" | awk '{print $2}')
      default_branch=$(echo "${line}" | awk '{print $3}')
      total=$((total + 1))
      provision_project "${project_id}" "${project_path}" "${default_branch}"
    done <<< "${projects}"
  done

  info ""
  info "=== Done: ${total} projects processed ==="
}

main "$@"
