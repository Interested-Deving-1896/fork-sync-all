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
  pa_list_project_coordinates \
  pa_project_default_branch \
  pa_read_project_file \
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

PA_PLATFORM="gitlab"
PA_API="https://gitlab.example/api/v4"
pa_api_get() {
  case "$1" in
    *'/groups/group%2Fsubgroup/projects?'*)
      printf '[{"path_with_namespace":"group/subgroup/project-one"}]\n'
      ;;
    *'/projects/group%2Fsubgroup%2Fproject-one/repository/files/README.md?'*)
      printf '{"content":"aGVsbG8K"}\n'
      ;;
    *'/projects/group%2Fsubgroup%2Fproject-one')
      printf '{"default_branch":"main"}\n'
      ;;
    *)
      return 1
      ;;
  esac
}

[[ "$(pa_list_project_coordinates group/subgroup true)" == \
  "group/subgroup/project-one" ]]
[[ "$(pa_project_default_branch group/subgroup project-one)" == "main" ]]
[[ "$(pa_read_project_file group/subgroup project-one README.md)" == "hello" ]]

echo "platform-adapter forge-neutral vocabulary: ok"
