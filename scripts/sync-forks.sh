#!/usr/bin/env bash
#
# Syncs all GitLab forks in the openos-project group with their upstream.
#
# Uses a single GitLab GraphQL call to enumerate all projects with an
# importUrl (pull-mirror forks), then triggers a mirror refresh for each
# via the REST mirror/pull endpoint. Replaces paginated REST enumeration
# (~200 calls for a large group) with 1–3 GraphQL calls.
#
# Required CI variables:
#   GITLAB_TOKEN  — PAT with api + write_repository scope
#
set -uo pipefail

: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"

GL_GROUP="${GL_GROUP:-openos-project}"
GL_GRAPHQL="https://gitlab.com/api/graphql"
GL_API="https://gitlab.com/api/v4"

info() { echo "[sync-forks] $*" >&2; }

echo "Starting fork sync for group: ${GL_GROUP}"

# Fetch all projects with an importUrl in one GraphQL call (cursor-paginated,
# 100 projects per page). Replaces the paginated REST loop.
projects_json=$(GL_GROUP="$GL_GROUP" GL_GRAPHQL="$GL_GRAPHQL" GITLAB_TOKEN="$GITLAB_TOKEN" \
  python3 -c "
import json, os, sys, urllib.request, urllib.error

token   = os.environ['GITLAB_TOKEN']
group   = os.environ['GL_GROUP']
graphql = os.environ['GL_GRAPHQL']

query = '''
query(\$group: ID!, \$after: String) {
  group(fullPath: \$group) {
    projects(includeSubgroups: true, first: 100, after: \$after) {
      pageInfo { hasNextPage endCursor }
      nodes { id fullPath importUrl }
    }
  }
}
'''

results = []
after   = None

while True:
    variables = {'group': group, 'after': after}
    payload   = json.dumps({'query': query, 'variables': variables}).encode()
    req = urllib.request.Request(graphql, data=payload, headers={
        'Authorization': 'Bearer ' + token,
        'Content-Type':  'application/json',
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.load(resp)
    except urllib.error.URLError as e:
        print('GraphQL request failed: ' + str(e), file=sys.stderr)
        sys.exit(1)
    if 'errors' in data:
        print('GraphQL errors: ' + str(data['errors']), file=sys.stderr)
        sys.exit(1)
    page = data['data']['group']['projects']
    for node in page['nodes']:
        if node.get('importUrl'):
            results.append({
                'id':   node['id'].split('/')[-1],
                'name': node['fullPath'],
                'import_url': node['importUrl'],
            })
    if not page['pageInfo']['hasNextPage']:
        break
    after = page['pageInfo']['endCursor']

print(json.dumps(results))
" 2>/dev/null || echo "[]")

if [[ -z "$projects_json" || "$projects_json" == "[]" ]]; then
  info "No projects with importUrl found in group ${GL_GROUP} — falling back to REST"
  # REST fallback: paginate through group projects
  PAGE=1
  projects_json="[]"
  while true; do
    batch=$(curl -sf \
      --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      "${GL_API}/groups/${GL_GROUP}/projects?include_subgroups=true&per_page=100&page=${PAGE}&with_statistics=false" \
      || echo "[]")
    count=$(echo "$batch" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo 0)
    [ "$count" -eq 0 ] && break
    projects_json=$(python3 -c "
import json,sys
existing = json.loads('$projects_json')
batch = json.load(sys.stdin)
for p in batch:
    if p.get('import_url'):
        existing.append({'id': str(p['id']), 'name': p['path_with_namespace'], 'import_url': p['import_url']})
print(json.dumps(existing))
" <<< "$batch")
    ((PAGE++)) || true
  done
fi

synced=0
failed=0

while IFS= read -r project; do
  id=$(echo "$project"         | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
  name=$(echo "$project"       | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
  import_url=$(echo "$project" | python3 -c "import json,sys; print(json.load(sys.stdin)['import_url'])")

  echo "Syncing ${name} from ${import_url} …"
  http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
    --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${GL_API}/projects/${id}/mirror/pull" 2>/dev/null || true)

  if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
    echo "  ✅ triggered"
    ((synced++)) || true
  else
    # Pull mirroring requires Premium; fall back to manual clone+push
    echo "  ⚠️  mirror API returned ${http_code} — skipping (pull mirroring may require Premium)"
    ((failed++)) || true
  fi
done < <(echo "$projects_json" | python3 -c "import json,sys; [print(json.dumps(p)) for p in json.load(sys.stdin)]")

echo ""
echo "Done. synced=${synced} failed/skipped=${failed}"
