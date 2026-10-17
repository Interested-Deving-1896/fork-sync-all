#!/usr/bin/env bash
# Shared README badge construction for inject-badges.sh and update-readmes.sh.
# Dynamic Eco CI badges require the numeric workflow ID stored by Eco CI.

[[ -n "${_README_BADGES_LOADED:-}" ]] && return 0
_README_BADGES_LOADED=1

README_ONA_BADGE_SVG="https://ona.com/build-with-ona.svg"
README_ONA_BADGE_BASE="https://app.ona.com/#"
README_KDE_ECO_BADGE="[![KDE Eco](https://img.shields.io/badge/KDE%20Eco-certified-brightgreen?logo=kde&logoColor=white&style=flat-square)](https://eco.kde.org/)"
README_BLUE_ANGEL_BADGE="[![Blue Angel](https://img.shields.io/badge/Blue%20Angel-DE--UZ%20215-0055a4?style=flat-square)](https://www.blauer-engel.de/en/certification/criteria)"

readme_urlencode() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

readme_ona_badge() {
  local target_url="$1"
  printf '[![Built with Ona](%s)](%s%s)\n' \
    "$README_ONA_BADGE_SVG" "$README_ONA_BADGE_BASE" "$target_url"
}

readme_eco_ci_badge() {
  local full_scm_path="$1" workflow_id="${2:-}"
  [[ -n "$workflow_id" ]] || return 0
  if [[ ! "$workflow_id" =~ ^[0-9]+$ ]]; then
    printf '[readme-badges] ECO_CI_WORKFLOW_ID must be numeric; omitting dynamic badge\n' >&2
    return 1
  fi

  local encoded_repo image_url dashboard_url
  encoded_repo=$(readme_urlencode "$full_scm_path") || return 1
  image_url="https://api.green-coding.io/v1/ci/badge/get?repo=${encoded_repo}&branch=main&workflow=${workflow_id}&mode=totals&metric=energy"
  dashboard_url="https://metrics.green-coding.io/ci.html?repo=${encoded_repo}&branch=main&workflow=${workflow_id}"
  printf '[![Energy](%s)](%s)\n' "$image_url" "$dashboard_url"
}

readme_eco_ci_workflow_id() {
  local full_scm_path="$1"
  [[ -n "${ECO_CI_REPO:-}" && "$full_scm_path" == "$ECO_CI_REPO" ]] || return 0
  printf '%s\n' "${ECO_CI_WORKFLOW_ID:-}"
}

readme_badge_line() {
  local target_url="$1" full_scm_path="$2" workflow_id="${3:-}"
  local line energy_badge
  line=$(readme_ona_badge "$target_url") || return 1
  if [[ "${ECO_BADGES:-true}" == "true" ]]; then
    line+=" ${README_KDE_ECO_BADGE} ${README_BLUE_ANGEL_BADGE}"
    energy_badge=$(readme_eco_ci_badge "$full_scm_path" "$workflow_id") || return 1
    [[ -n "$energy_badge" ]] && line+=$'\n'"${energy_badge}"
  fi
  printf '%s\n' "$line"
}

readme_has_legacy_eco_ci_badge() {
  grep -qE 'api\.green-coding\.io/v1/ci/badge/get[^)]*workflow=[^&)]*\.ya?ml' <<<"$1"
}
