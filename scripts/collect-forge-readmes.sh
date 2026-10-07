#!/usr/bin/env bash
# Collect README content from one forge namespace as tab-separated base64 records.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${REPO_ROOT}/scripts/includes/platform-adapter.sh"

usage() {
  echo "Usage: $0 PLATFORM HOST NAMESPACE [INCLUDE_NESTED]" >&2
}

[[ $# -ge 3 ]] || { usage; exit 2; }
platform=$1
host=$2
namespace=$3
include_nested=${4:-false}

case "$platform" in
  github) token=${GH_TOKEN:-${SYNC_TOKEN:-}} ;;
  gitlab) token=${GITLAB_TOKEN:-} ;;
  gitea) token=${GITEA_TOKEN:-} ;;
  forgejo) token=${FORGEJO_TOKEN:-${GITEA_TOKEN:-}} ;;
  codeberg) token=${CODEBERG_TOKEN:-${FORGEJO_TOKEN:-${GITEA_TOKEN:-}}} ;;
  *) echo "collect-forge-readmes: unsupported platform: ${platform}" >&2; exit 2 ;;
esac
[[ -n "$token" ]] || {
  echo "collect-forge-readmes: no token configured for ${platform}" >&2
  exit 3
}

export PLATFORM_TOKEN="$token"
export PLATFORM_NAMESPACE="$namespace"
pa_init "$platform" "$host" >/dev/null

temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT

while IFS= read -r coordinate; do
  [[ -n "$coordinate" ]] || continue
  project=${coordinate##*/}
  project_namespace=${coordinate%/*}
  readme_file="${temporary}/readme"
  if pa_read_project_file "$project_namespace" "$project" README.md >"$readme_file"; then
    digest=$(sha256sum "$readme_file" | awk '{print $1}')
    content=$(base64 -w 0 "$readme_file")
    printf '%s\t%s\t%s\t%s\n' "$coordinate" present "$digest" "$content"
  else
    printf '%s\t%s\t\t\n' "$coordinate" missing
  fi
done < <(pa_list_project_coordinates "$namespace" "$include_nested")
