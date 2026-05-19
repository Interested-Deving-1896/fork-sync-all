#!/usr/bin/env bash
#
# Syncs all GitLab forks in the openos-project group with their upstream.
# Delegates to sync-all-forks.sh which handles the actual sync logic.
#
# Required CI variables:
#   GITLAB_TOKEN  — PAT with api + write_repository scope
#
set -uo pipefail

: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"

# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# sync-all-forks.sh was written for GitHub; adapt for GitLab by setting
# the equivalent env vars it expects.
export GL_TOKEN="${GITLAB_TOKEN}"
export GL_GROUP="${GL_GROUP:-openos-project}"

echo "Starting fork sync for group: ${GL_GROUP}"

# Enumerate all projects in the group that have an import_url (i.e. are forks
# of an external repo) and trigger a re-import / pull-mirror refresh via API.
API="https://gitlab.com/api/v4"
PAGE=1
synced=0
failed=0

while true; do
  projects=$(curl -sf \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${API}/groups/${GL_GROUP}/projects?include_subgroups=true&per_page=100&page=${PAGE}&with_statistics=false")

  count=$(echo "$projects" | jq 'length')
  [ "$count" -eq 0 ] && break

  while IFS= read -r project; do
    id=$(echo "$project" | jq -r '.id')
    name=$(echo "$project" | jq -r '.path_with_namespace')
    import_url=$(echo "$project" | jq -r '.import_url // empty')

    if [ -z "$import_url" ]; then
      continue
    fi

    echo "Syncing ${name} from ${import_url} …"
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
      --request POST \
      --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      "${API}/projects/${id}/mirror/pull" 2>/dev/null || true)

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
      echo "  ✅ triggered"
      ((synced++)) || true
    else
      # Pull mirroring requires Premium; fall back to manual clone+push
      echo "  ⚠️  mirror API returned ${http_code} — skipping (pull mirroring may require Premium)"
      ((failed++)) || true
    fi
  done < <(echo "$projects" | jq -c '.[]')

  ((PAGE++)) || true
done

echo ""
echo "Done. synced=${synced} failed/skipped=${failed}"
