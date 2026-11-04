#!/usr/bin/env bash
# Shared README badge construction for inject-badges.sh and update-readmes.sh.
[[ -n "${_README_BADGES_LOADED:-}" ]] && return 0
_README_BADGES_LOADED=1
_README_BADGES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
README_AGENT_BADGE_TOOL="${_README_BADGES_DIR}/../agent-badge-registry.py"
README_LANGUAGE_BADGE_TOOL="${_README_BADGES_DIR}/../programming-language-badge-registry.py"
README_LANGUAGE_BADGE_CONFIG="${README_LANGUAGE_BADGE_CONFIG:-${_README_BADGES_DIR}/../../config/programming-language-badges.json}"
README_AGENT_BADGE_CONFIG="${README_AGENT_BADGE_CONFIG:-${_README_BADGES_DIR}/../../config/ai-agent-badges.json}"
# shellcheck disable=SC2034 # Consumed by scripts/inject-badges.sh after sourcing this helper.
README_AGENT_BADGE_MARKER=$(python3 "$README_AGENT_BADGE_TOOL" --config "$README_AGENT_BADGE_CONFIG" required-marker) || return 1
README_KDE_ECO_BADGE="[![KDE Eco](https://img.shields.io/badge/KDE%20Eco-certified-brightgreen?logo=kde&logoColor=white&style=flat-square)](https://eco.kde.org/)"
README_BLUE_ANGEL_BADGE="[![Blue Angel](https://img.shields.io/badge/Blue%20Angel-DE--UZ%20215-0055a4?style=flat-square)](https://www.blauer-engel.de/en/certification/criteria)"

readme_urlencode() {
  python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}
readme_agent_badges() {
  python3 "$README_AGENT_BADGE_TOOL" --config "$README_AGENT_BADGE_CONFIG" render --repo-url "$1"
}
readme_language_badges() {
  [[ -n "$1" ]] || return 0
  python3 "$README_LANGUAGE_BADGE_TOOL" --config "$README_LANGUAGE_BADGE_CONFIG" render --languages-json "$1"
}
readme_strip_managed_badges() {
  local content
  content=$(cat) || return 1
  content=$(printf '%s\n' "$content" | python3 "$README_AGENT_BADGE_TOOL" --config "$README_AGENT_BADGE_CONFIG" strip-managed) || return 1
  printf '%s\n' "$content" | python3 "$README_LANGUAGE_BADGE_TOOL" --config "$README_LANGUAGE_BADGE_CONFIG" strip-managed
}
readme_eco_ci_badge() {
  local full_scm_path="$1" workflow_id="${2:-}"
  [[ -n "$workflow_id" ]] || return 0
  [[ "$workflow_id" =~ ^[0-9]+$ ]] || { printf '%s\n' '[readme-badges] ECO_CI_WORKFLOW_ID must be numeric' >&2; return 1; }
  local encoded_repo
  encoded_repo=$(readme_urlencode "$full_scm_path") || return 1
  printf '[![Energy](https://api.green-coding.io/v1/ci/badge/get?repo=%s&branch=main&workflow=%s&mode=totals&metric=energy)](https://metrics.green-coding.io/ci.html?repo=%s&branch=main&workflow=%s)\n' "$encoded_repo" "$workflow_id" "$encoded_repo" "$workflow_id"
}
readme_eco_ci_workflow_id() {
  [[ -n "${ECO_CI_REPO:-}" && "$1" == "$ECO_CI_REPO" ]] || return 0
  printf '%s\n' "${ECO_CI_WORKFLOW_ID:-}"
}
readme_badge_line() {
  local target_url="$1" full_scm_path="$2" workflow_id="${3:-}" languages_json="${4:-}"
  local line energy_badge language_badges
  line=$(readme_agent_badges "$target_url") || return 1
  if [[ "${ECO_BADGES:-true}" == "true" ]]; then
    line+=
  printf '%s\n' "$line"
}
readme_has_legacy_eco_ci_badge() {
  grep -qE 'api\.green-coding\.io/v1/ci/badge/get[^)]*workflow=[^&)]*\.ya?ml' <<<"$1"
}
\n'"$README_KDE_ECO_BADGE $README_BLUE_ANGEL_BADGE"
    energy_badge=$(readme_eco_ci_badge "$full_scm_path" "$workflow_id") || return 1
  fi
  if [[ "${LANGUAGE_BADGES:-false}" == "true" && -n "$languages_json" ]]; then
    language_badges=$(readme_language_badges "$languages_json") || return 1
    [[ -n "$language_badges" ]] && line+=
  printf '%s\n' "$line"
}
readme_has_legacy_eco_ci_badge() {
  grep -qE 'api\.green-coding\.io/v1/ci/badge/get[^)]*workflow=[^&)]*\.ya?ml' <<<"$1"
}
\n'"$language_badges"
  fi
  [[ -n "$energy_badge" ]] && line+=
  printf '%s\n' "$line"
}
readme_has_legacy_eco_ci_badge() {
  grep -qE 'api\.green-coding\.io/v1/ci/badge/get[^)]*workflow=[^&)]*\.ya?ml' <<<"$1"
}
\n'"$energy_badge"
  printf '%s\n' "$line"
}
readme_has_legacy_eco_ci_badge() {
  grep -qE 'api\.green-coding\.io/v1/ci/badge/get[^)]*workflow=[^&)]*\.ya?ml' <<<"$1"
}
