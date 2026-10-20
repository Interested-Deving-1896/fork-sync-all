#!/bin/bash
# scripts/sync-upstream-mirrors.sh
#
# Syncs all upstream mirror repos in openos-project/upstream-mirrors from
# their original GitHub sources. Runs as a scheduled GitLab CI job.
#
# Required CI variable: GITLAB_TOKEN (masked) — GitLab PAT with api + write_repository scope

set -euo pipefail

GITLAB_API="https://gitlab.com/api/v4"
MIRROR_GROUP="openos-project/upstream-mirrors"
MIRROR_GROUP_ENCODED="openos-project%2Fupstream-mirrors"

info()  { echo "[sync] $*" >&2; }
warn()  { echo "[warn] $*" >&2; }
error() { echo "[error] $*" >&2; }

# Fetch every page of projects in the upstream-mirrors group. GitLab's
# per_page limit means a single page silently omits projects after the first
# 100; aggregate pages before starting any mirror writes.
info "Fetching project list from ${MIRROR_GROUP}..."
projects_pages=$(mktemp)
trap 'rm -f "$projects_pages"' EXIT
page=1
while :; do
  response_file=$(mktemp)
  http_code=$(curl -sS --output "$response_file" --write-out '%{http_code}' \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${GITLAB_API}/groups/${MIRROR_GROUP_ENCODED}/projects?per_page=100&include_subgroups=false&page=${page}") || {
      error "GitLab project listing transport failed on page ${page}."
      rm -f "$response_file"
      exit 1
    }
  if [[ "$http_code" != "200" ]]; then
    error "GitLab project listing failed (HTTP ${http_code}, page ${page})."
    head -c 1200 "$response_file" >&2 || true
    echo >&2
    rm -f "$response_file"
    exit 1
  fi
  if ! python3 - "$response_file" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    if not isinstance(data, list):
        raise ValueError("expected a JSON array")
except Exception as exc:
    print(f"Invalid GitLab projects response: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
  then
    rm -f "$response_file"
    exit 1
  fi
  count=$(python3 - "$response_file" <<'PY'
import json, sys
print(len(json.load(open(sys.argv[1], encoding="utf-8"))))
PY
)
  # Normalize each validated page to one compact JSON line. This avoids relying
  # on GitLab's response whitespace/layout when aggregating multiple pages.
  python3 - "$response_file" "$projects_pages" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    page = json.load(source)
with open(sys.argv[2], "a", encoding="utf-8") as aggregate:
    aggregate.write(json.dumps(page, separators=(",", ":")) + chr(10))
PY
  rm -f "$response_file"
  [[ "$count" -lt 100 ]] && break
  page=$((page + 1))
done
projects=$(python3 - "$projects_pages" <<'PY'
import json, sys
pages = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
print(json.dumps([project for page in pages for project in page]))
PY
)

total=$(echo "$projects" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
info "Found ${total} mirror projects"

SYNCED=0
SKIPPED=0
FAILED=0

# Process each project in the current Bash shell so counters persist.
while read -r _pid name gl_url gh_url; do
  if [ -z "$gh_url" ]; then
    info "SKIP (no GitHub source): ${name}"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  info "Syncing ${name} ..."
  work_dir=$(mktemp -d)

  # Inject token into GitLab URL
  gl_auth_url="${gl_url/https:\/\//https://oauth2:${GITLAB_TOKEN}@}"

  if git clone --mirror "$gh_url" "$work_dir" 2>/dev/null; then
    cd "$work_dir"
    if git push --mirror "$gl_auth_url" 2>/dev/null; then
      info "  ✅ ${name} synced"
      SYNCED=$((SYNCED + 1))
    else
      warn "  ❌ ${name} push failed"
      FAILED=$((FAILED + 1))
    fi
    cd /
  else
    warn "  ❌ ${name} clone from GitHub failed"
    FAILED=$((FAILED + 1))
  fi

  rm -rf "$work_dir"
done < <(python3 -c "
import sys, json
for p in json.load(sys.stdin):
    src = p.get('import_url') or ''
    # Skip projects with no GitHub source (manually pushed, e.g. buildroot, linux-xanmod)
    if not src.startswith('https://github.com'):
        src = ''
    print(p['id'], p['name'], p['http_url_to_repo'], src)
" <<< "$projects")

echo ""
info "Done — synced: ${SYNCED} | skipped: ${SKIPPED} | failed: ${FAILED}"
