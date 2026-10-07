#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../includes" && pwd)/platform-adapter.sh"

PLATFORM_NAMESPACE="group/subgroup"
PLATFORM_NAMESPACE_KIND="subgroup"
PLATFORM_TOKEN="test-only-token"
pa_init github >/dev/null
[[ "$PA_NAMESPACE" == "group/subgroup" ]]
[[ "$PA_NAMESPACE_KIND" == "subgroup" ]]

for function_name in \
  pa_list_projects \
  pa_project_exists \
  pa_project_clone_url \
  pa_project_push_url \
  pa_create_project; do
  declare -F "$function_name" >/dev/null
done

pa_list_repos() { printf '%s\n' project-one project-two; }
pa_repo_exists() { [[ "$1/$2" == "group/project-one" ]]; }
pa_clone_url() { printf 'https://forge.example/%s/%s.git\n' "$1" "$2"; }
pa_push_url() { pa_clone_url "$@"; }
pa_create_repo() { printf 'created %s/%s\n' "$1" "$2"; }

[[ "$(pa_list_projects group)" == $'project-one\nproject-two' ]]
pa_project_exists group project-one
[[ "$(pa_project_clone_url group project-one)" == \
  "https://forge.example/group/project-one.git" ]]
[[ "$(pa_project_push_url group project-one)" == \
  "https://forge.example/group/project-one.git" ]]
[[ "$(pa_create_project group project-one)" == "created group/project-one" ]]

echo "platform-adapter forge-neutral vocabulary: ok"
