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
normalized_projects=""
trap 'rm -f "$projects_pages" ${normalized_projects:+"$normalized_projects"}' EXIT
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
# Validate every project record and write a NUL-delimited stream to a
# temporary file. This producer is checked before the sync loop starts, so a
# malformed record cannot be hidden by process substitution or cause a partial
# mirror update. NUL delimiters preserve spaces in project names and URLs.
normalized_projects=$(mktemp)
python3 - "$projects_pages" "$normalized_projects" <<'PY'
import json, sys
source_path, output_path = sys.argv[1:]
try:
    with open(source_path, encoding="utf-8") as source:
        pages = [json.loads(line) for line in source if line.strip()]
    projects = []
    for page_number, page in enumerate(pages, start=1):
        if not isinstance(page, list):
            raise ValueError(f"page {page_number} is not an array")
        for item_number, project in enumerate(page, start=1):
            where = f"page {page_number}, project {item_number}"
            if not isinstance(project, dict):
                raise ValueError(f"{where} is not an object")
            if not isinstance(project.get("id"), int) or isinstance(project.get("id"), bool):
                raise ValueError(f"{where} has missing/invalid id")
            for key in ("name", "http_url_to_repo"):
                value = project.get(key)
                if not isinstance(value, str) or not value or "\x00" in value:
                    raise ValueError(f"{where} has missing/invalid {key}")
            # The GitLab token is inserted into this URL for the mirror push.
            # Validate the exact destination host and expected group path before
            # credentials are attached; HTTPS alone is not a sufficient boundary.
            from urllib.parse import urlsplit
            try:
                destination = urlsplit(project["http_url_to_repo"])
                valid_destination = (
                    destination.scheme == "https"
                    and destination.hostname == "gitlab.com"
                    and destination.username is None
                    and destination.password is None
                    and destination.port is None
                    and destination.query == ""
                    and destination.fragment == ""
                    and destination.path.startswith("/openos-project/upstream-mirrors/")
                    and destination.path != "/openos-project/upstream-mirrors/"
                    # GitLab project paths are not expected to need percent escapes.
                    # Reject escapes (including double-encoded forms), backslashes,
                    # controls, and dot segments before attaching the write token.
                    and "%" not in destination.path
                    and "\\" not in destination.path
                    and not any(ord(ch) < 32 or ord(ch) == 127 for ch in destination.path)
                    and all(segment not in (".", "..") for segment in destination.path.split("/"))
                )
            except ValueError:
                valid_destination = False
            if not valid_destination:
                raise ValueError(f"{where} has invalid http_url_to_repo destination")
            source = project.get("import_url")
            if source is not None and (not isinstance(source, str) or "\x00" in source):
                raise ValueError(f"{where} has invalid import_url")
            source = source or ""
            # Require the exact HTTPS hostname. A string-prefix check would
            # incorrectly accept lookalike hosts such as github.com.example.invalid.
            if source:
                from urllib.parse import urlsplit
                try:
                    parsed_source = urlsplit(source)
                    valid_github_source = (
                        parsed_source.scheme == "https"
                        and parsed_source.hostname == "github.com"
                        and parsed_source.username is None
                        and parsed_source.password is None
                    )
                except ValueError:
                    valid_github_source = False
                if not valid_github_source:
                    source = ""
            projects.append((str(project["id"]), project["name"],
                             project["http_url_to_repo"], source))
    with open(output_path, "wb") as output:
        for record in projects:
            for field in record:
                output.write(field.encode("utf-8") + b"\0")
    print(f"Validated {len(projects)} mirror project records", file=sys.stderr)
except Exception as exc:
    print(f"Invalid GitLab project data: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
info "Validated project listing; normalized stream is ready"

SYNCED=0
SKIPPED=0
FAILED=0

# Process records in the current Bash shell so counters persist.
while IFS= read -r -d '' _pid && IFS= read -r -d '' name &&
      IFS= read -r -d '' gl_url && IFS= read -r -d '' gh_url; do
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
done < "$normalized_projects"

rm -f "$normalized_projects"

echo ""
info "Done — synced: ${SYNCED} | skipped: ${SKIPPED} | failed: ${FAILED}"
