#!/usr/bin/env bash
#
# scripts/eco/eco-ci-shell.sh — eco-ci-energy-estimation shell wrapper
#
# Wraps the green-coding-solutions/eco-ci-energy-estimation bash scripts for
# use on CI platforms that don't support GitHub Actions or GitLab CI includes:
#   - Gitea Actions (act-based runners)
#   - Forgejo Actions
#   - Codeberg CI (Woodpecker)
#   - Jenkins
#   - Any POSIX shell CI environment
#
# The eco-ci scripts are fetched from the upstream repo at runtime and cached
# in /tmp/eco-ci-scripts/ for the duration of the job.
#
# USAGE:
#   source scripts/eco/eco-ci-shell.sh
#   eco_start "my-workflow"
#   # ... do work ...
#   eco_measure "step label"
#   # ... more work ...
#   eco_display
#
# ENV VARS (all optional):
#   ECO_CI_VERSION      — upstream tag/branch to fetch (default: main)
#   ECO_CI_SEND_DATA    — send metrics to metrics.green-coding.io (default: true)
#   ECO_CI_LABEL        — default label for measurements (default: measurement)
#   ECO_CI_BRANCH       — branch name for badge (default: $CI_COMMIT_BRANCH or $BRANCH_NAME)
#   ECO_CI_JSON_OUTPUT  — write lap data to /tmp/eco-ci/lap-data.json (default: false)
#   ECO_CI_MACHINE      — machine identifier for CarbonDB (default: auto-detected)
#
# PLATFORM DETECTION:
#   The script auto-detects the CI platform from environment variables and sets
#   ECO_CI_SOURCE accordingly (used by eco-ci for badge labelling).
#
# Guard against double-sourcing
[[ -n "${_ECO_CI_SHELL_LOADED:-}" ]] && return 0
_ECO_CI_SHELL_LOADED=1

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
ECO_CI_VERSION="${ECO_CI_VERSION:-main}"
ECO_CI_SEND_DATA="${ECO_CI_SEND_DATA:-true}"
ECO_CI_LABEL="${ECO_CI_LABEL:-measurement}"
ECO_CI_JSON_OUTPUT="${ECO_CI_JSON_OUTPUT:-false}"
_ECO_SCRIPT_DIR="/tmp/eco-ci-scripts"
_ECO_BASE_URL="https://raw.githubusercontent.com/green-coding-solutions/eco-ci-energy-estimation/${ECO_CI_VERSION}"

_eco_info() { echo "[eco-ci] $*" >&2; }
_eco_warn() { echo "[eco-ci][warn] $*" >&2; }

# ── Platform detection ────────────────────────────────────────────────────────
_eco_detect_platform() {
  if [[ -n "${GITEA_ACTIONS:-}" ]] || [[ "${CI_PLATFORM:-}" == "gitea" ]]; then
    echo "gitea"
  elif [[ -n "${FORGEJO_ACTIONS:-}" ]] || [[ "${CI_PLATFORM:-}" == "forgejo" ]]; then
    echo "forgejo"
  elif [[ -n "${CI_WOODPECKER_VERSION:-}" ]] || [[ "${CI_SYSTEM_NAME:-}" == "woodpecker" ]]; then
    echo "codeberg"
  elif [[ -n "${JENKINS_URL:-}" ]]; then
    echo "jenkins"
  elif [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "github"
  elif [[ -n "${GITLAB_CI:-}" ]]; then
    echo "gitlab"
  else
    echo "unknown"
  fi
}

# ── Branch detection ──────────────────────────────────────────────────────────
_eco_detect_branch() {
  # Try common CI env vars in order of preference
  echo "${ECO_CI_BRANCH:-${CI_COMMIT_BRANCH:-${BRANCH_NAME:-${GITHUB_REF_NAME:-${GIT_BRANCH:-main}}}}}"
}

# ── Fetch eco-ci scripts ──────────────────────────────────────────────────────
_eco_fetch_scripts() {
  if [[ -f "${_ECO_SCRIPT_DIR}/start_measurement.sh" ]]; then
    return 0  # already fetched this job
  fi

  mkdir -p "${_ECO_SCRIPT_DIR}"

  local scripts=(
    "scripts/start_measurement.sh"
    "scripts/get_measurement.sh"
    "scripts/display_results.sh"
  )

  for script in "${scripts[@]}"; do
    local name
    name=$(basename "$script")
    local dest="${_ECO_SCRIPT_DIR}/${name}"

    if ! curl -sf --retry 3 --retry-delay 5 \
        "${_ECO_BASE_URL}/${script}" -o "$dest" 2>/dev/null; then
      _eco_warn "Failed to fetch ${name} from upstream — eco-ci measurements disabled"
      return 1
    fi
    chmod +x "$dest"
  done

  _eco_info "Fetched eco-ci scripts (version: ${ECO_CI_VERSION})"
  return 0
}

# ── Public API ────────────────────────────────────────────────────────────────

# eco_start [workflow_name]
#   Initialise measurement. Call once at the start of the job.
eco_start() {
  local workflow_name="${1:-${ECO_CI_LABEL}}"
  local platform
  platform=$(_eco_detect_platform)
  local branch
  branch=$(_eco_detect_branch)

  _eco_info "Starting energy measurement (platform: ${platform}, branch: ${branch})"

  if ! _eco_fetch_scripts; then
    _eco_warn "eco_start: skipping (scripts unavailable)"
    return 0
  fi

  export ECO_CI_SEND_DATA
  export ECO_CI_JSON_OUTPUT
  export ECO_CI_SOURCE="${platform}"
  export BRANCH="${branch}"

  # The start_measurement script expects these env vars
  export WORKFLOW_ID="${workflow_name}"
  export RUN_ID="${CI_PIPELINE_ID:-${BUILD_NUMBER:-${GITHUB_RUN_ID:-0}}}"

  bash "${_ECO_SCRIPT_DIR}/start_measurement.sh" 2>/dev/null || {
    _eco_warn "eco_start: measurement init failed (non-fatal)"
  }
}

# eco_measure [label]
#   Record a spot measurement at this point in the job.
eco_measure() {
  local label="${1:-${ECO_CI_LABEL}}"

  if [[ ! -f "${_ECO_SCRIPT_DIR}/get_measurement.sh" ]]; then
    _eco_warn "eco_measure: scripts not available — skipping"
    return 0
  fi

  export ECO_CI_LABEL="${label}"
  bash "${_ECO_SCRIPT_DIR}/get_measurement.sh" 2>/dev/null || {
    _eco_warn "eco_measure '${label}': failed (non-fatal)"
  }
}

# eco_display
#   Print the energy summary table and post badge to metrics.green-coding.io.
#   Call once at the end of the job (e.g. in an after_script or post-build step).
eco_display() {
  if [[ ! -f "${_ECO_SCRIPT_DIR}/display_results.sh" ]]; then
    _eco_warn "eco_display: scripts not available — skipping"
    return 0
  fi

  bash "${_ECO_SCRIPT_DIR}/display_results.sh" 2>/dev/null || {
    _eco_warn "eco_display: failed (non-fatal)"
  }

  # Print lap data path if JSON output was enabled
  if [[ "${ECO_CI_JSON_OUTPUT}" == "true" ]] && [[ -f "/tmp/eco-ci/lap-data.json" ]]; then
    _eco_info "Lap data written to /tmp/eco-ci/lap-data.json"
  fi
}

# ── Woodpecker CI (Codeberg) pipeline snippet ─────────────────────────────────
# To use in a Woodpecker pipeline (.woodpecker.yml):
#
#   steps:
#     eco-audit:
#       image: ubuntu:22.04
#       commands:
#         - apt-get update -qq && apt-get install -y curl bash jq awk
#         - source scripts/eco/eco-ci-shell.sh
#         - eco_start "eco-audit"
#         - bash scripts/eco/eco-audit.sh
#         - eco_measure "eco-audit script"
#         - eco_display

# ── Jenkins pipeline snippet ──────────────────────────────────────────────────
# To use in a Jenkinsfile:
#
#   stage('Eco Audit') {
#     steps {
#       sh '''
#         source scripts/eco/eco-ci-shell.sh
#         eco_start "eco-audit"
#         bash scripts/eco/eco-audit.sh
#         eco_measure "eco-audit script"
#         eco_display
#       '''
#     }
#   }

# ── Gitea / Forgejo Actions snippet ──────────────────────────────────────────
# Gitea/Forgejo Actions use the same YAML syntax as GitHub Actions but don't
# support third-party Actions from the GitHub marketplace. Use this script
# directly instead:
#
#   - name: Eco CI — start measurement
#     run: |
#       source scripts/eco/eco-ci-shell.sh
#       eco_start "eco-audit"
#
#   - name: Run eco audit
#     run: bash scripts/eco/eco-audit.sh
#
#   - name: Eco CI — measure + display
#     run: |
#       source scripts/eco/eco-ci-shell.sh
#       eco_measure "eco-audit script"
#       eco_display
