#!/usr/bin/env bash
#
# Generation-aware mirror of the two distinct Penguins-Eggs upstreams to their
# existing GitLab projects. The book repository remains a read-only snapshot.
#
# Legacy: pieroproietti/penguins-eggs-legacy:master -> project 81413430
# Modern: pieroproietti/penguins-eggs:main          -> project 81412997
#
# Required CI variable:
#   GITLAB_TOKEN — PAT with api + write_repository scope
# Optional:
#   GH_TOKEN — improves GitHub release API reliability
#   DRY_RUN=true — inspect refs/releases without pushing or creating releases
#
# Only the explicitly listed upstream branches are force-updated. Tags are
# additive. Local-only branches in GitLab are never pruned or overwritten.

set -uo pipefail

: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"

GL_API="https://gitlab.com/api/v4"
GH_TOKEN="${GH_TOKEN:-}"
DRY_RUN="${DRY_RUN:-false}"
case "${DRY_RUN,,}" in
  true|1|yes) DRY_RUN=true ;;
  *) DRY_RUN=false ;;
esac

if [[ -n "$GH_TOKEN" ]]; then
  # shellcheck source=scripts/includes/gh-api.sh
  source "$(dirname "${BASH_SOURCE[0]}")/includes/gh-api.sh"
fi

info() { echo "[sync] $*" >&2; }
warn() { echo "[warn] $*" >&2; }

# gl_get <url> — authenticated GitLab GET with bounded transient retries.
gl_get() {
  local url="$1" attempt max_retries=3 out http_code body
  for ((attempt=1; attempt<=max_retries; attempt++)); do
    out=$(curl -sS -w "\n__HTTP_CODE__:%{http_code}" \
      --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "$url" 2>/dev/null) || true
    http_code=$(printf '%s\n' "$out" | grep -o '__HTTP_CODE__:[0-9]*' | cut -d: -f2)
    body=$(printf '%s\n' "$out" | sed '/__HTTP_CODE__:/d')

    if [[ "$http_code" == "429" ]]; then
      warn "GitLab rate limited — sleeping 60s (attempt ${attempt}/${max_retries})"
      sleep 60
      continue
    fi
    if [[ "$http_code" =~ ^5 ]]; then
      warn "GitLab server error ${http_code} — retrying in 10s (attempt ${attempt}/${max_retries})"
      sleep 10
      continue
    fi
    if [[ ! "$http_code" =~ ^2 ]]; then
      warn "GitLab request failed with HTTP ${http_code:-unknown}: ${url}"
      return 1
    fi
    printf '%s\n' "$body"
    return 0
  done
  warn "gl_get failed after ${max_retries} attempts: ${url}"
  return 1
}

# Source | GitLab project ID | exact upstream branches to mirror.
# Project IDs are retained; only the upstream identities/branches are corrected.
REPOS=(
  "pieroproietti/penguins-eggs-legacy|81413430|master"
  "pieroproietti/penguins-eggs|81412997|main"
)

SYNCED=0
FAILED=0
PLANNED=0

for entry in "${REPOS[@]}"; do
  gh_path="${entry%%|*}"
  rest="${entry#*|}"
  gl_pid="${rest%%|*}"
  upstream_branches="${rest##*|}"
  gl_repo_name="${gh_path##*/}"
  repo_failed=false

  info "──────────────────────────────────────────"
  info "Syncing ${gh_path} → GitLab project ${gl_pid}"

  if ! gl_project=$(gl_get "${GL_API}/projects/${gl_pid}"); then
    warn "Could not fetch GitLab project ${gl_pid}"
    FAILED=$((FAILED + 1))
    continue
  fi
  gl_url=$(printf '%s' "$gl_project" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('http_url_to_repo',''))" 2>/dev/null) || gl_url=""
  if [[ -z "$gl_url" ]]; then
    warn "GitLab project ${gl_pid} returned no clone URL"
    FAILED=$((FAILED + 1))
    continue
  fi

  gl_auth_url="${gl_url/https:\/\//https://oauth2:${GITLAB_TOKEN}@}"
  gh_url="https://github.com/${gh_path}.git"
  work_dir=$(mktemp -d) || {
    warn "Could not create temporary work directory"
    FAILED=$((FAILED + 1))
    continue
  }

  info "Cloning ${gh_url} ..."
  if ! git clone --mirror "$gh_url" "$work_dir/mirror"; then
    warn "Clone failed for ${gh_path}"
    FAILED=$((FAILED + 1))
    rm -rf "$work_dir"
    continue
  fi

  cd "$work_dir/mirror" || {
    warn "Could not enter mirror checkout for ${gh_path}"
    FAILED=$((FAILED + 1))
    rm -rf "$work_dir"
    continue
  }

  # Tags are additive; do not delete destination-only tags.
  if [[ "$DRY_RUN" == true ]]; then
    info "[dry-run] Would push tags to GitLab project ${gl_pid}"
  elif git push "$gl_auth_url" --tags; then
    info "Tags pushed"
  else
    warn "Tag push failed for ${gh_path}"
    repo_failed=true
  fi

  # Update only configured upstream branches. Missing configured refs are
  # errors rather than silently reported successful skips.
  for branch in $upstream_branches; do
    ref="refs/heads/${branch}"
    if ! git show-ref --verify --quiet "$ref"; then
      warn "Configured upstream branch ${branch} is missing from ${gh_path}"
      repo_failed=true
      continue
    fi
    if [[ "$DRY_RUN" == true ]]; then
      info "[dry-run] Would update branch ${branch} in GitLab project ${gl_pid}"
    elif git push "$gl_auth_url" "+${ref}:${ref}"; then
      info "Branch ${branch} pushed"
    else
      warn "Branch push failed: ${gh_path}:${branch}"
      repo_failed=true
    fi
  done

  # Mirror GitHub release notes when available. The environment is passed
  # explicitly so the helper cannot silently post to an empty project path.
  if [[ "$DRY_RUN" == true ]]; then
    info "[dry-run] Release creation skipped"
  elif [[ "$repo_failed" == false ]]; then
    if [[ -n "$GH_TOKEN" ]]; then
      gh_releases=$(gh_get "https://api.github.com/repos/${gh_path}/releases?per_page=100" 2>/dev/null) || gh_releases="[]"
    else
      gh_releases=$(curl -fsS "https://api.github.com/repos/${gh_path}/releases?per_page=100" 2>/dev/null) || gh_releases="[]"
    fi
    if gl_releases=$(gl_get "${GL_API}/projects/${gl_pid}/releases?per_page=100"); then
      existing_tags=$(printf '%s' "$gl_releases" | python3 -c \
        "import json,sys; print('\\n'.join(r['tag_name'] for r in json.load(sys.stdin)))" 2>/dev/null) || {
        warn "Could not parse existing GitLab releases for project ${gl_pid}"
        repo_failed=true
        existing_tags=""
      }
      if [[ "$repo_failed" == false ]]; then
        GL_API="$GL_API" GL_PID="$gl_pid" GH_PATH="$gh_path" \
          GITLAB_TOKEN="$GITLAB_TOKEN" EXISTING_TAGS="$existing_tags" \
          GH_RELEASES_JSON="$gh_releases" python3 - <<'PYEOF'
import json
import os
import sys
import urllib.error
import urllib.request

try:
    releases = json.loads(os.environ["GH_RELEASES_JSON"])
    if not isinstance(releases, list):
        raise ValueError("GitHub releases response is not a JSON array")
except (KeyError, ValueError, json.JSONDecodeError) as exc:
    print(f"[warn] Invalid GitHub releases response: {exc}", file=sys.stderr)
    sys.exit(1)

token = os.environ["GITLAB_TOKEN"]
api = os.environ["GL_API"]
project_id = os.environ["GL_PID"]
gh_path = os.environ["GH_PATH"]
existing = set(os.environ.get("EXISTING_TAGS", "").splitlines())

for release in releases:
    tag = release.get("tag_name")
    if not tag:
        print("[warn] Skipping release without tag_name", file=sys.stderr)
        continue
    if tag in existing:
        print(f"[sync] Release {tag} already exists")
        continue
    published = release.get("published_at")
    if not published:
        print(f"[sync] Release {tag} has no published_at; skipping")
        continue
    description = (
        f"> Mirrored from [{gh_path} {tag}]"
        f"(https://github.com/{gh_path}/releases/tag/{tag})\n\n"
        f"{release.get('body') or ''}"
    )
    payload = json.dumps({
        "name": release.get("name") or tag,
        "tag_name": tag,
        "description": description,
        "released_at": published,
    }).encode()
    request = urllib.request.Request(
        f"{api}/projects/{project_id}/releases",
        data=payload,
        headers={"PRIVATE-TOKEN": token, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request) as response:
            response.read()
        print(f"[sync] Created GitLab release {tag}")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        if "already exists" in body or "already been taken" in body:
            print(f"[sync] Release {tag} already exists")
        else:
            print(f"[warn] Release {tag} failed: HTTP {exc.code} {body[:200]}", file=sys.stderr)
            sys.exit(1)
    except urllib.error.URLError as exc:
        print(f"[warn] Release {tag} failed: {exc}", file=sys.stderr)
        sys.exit(1)
PYEOF
        if [[ $? -ne 0 ]]; then
          warn "Release synchronization failed for ${gh_path}"
          repo_failed=true
        fi
      fi
    else
      warn "Could not list existing GitLab releases for project ${gl_pid}"
      repo_failed=true
    fi
  else
    info "Skipping release creation after a ref push failure"
  fi

  cd /
  rm -rf "$work_dir"

  if [[ "$DRY_RUN" == true ]]; then
    PLANNED=$((PLANNED + 1))
    info "[dry-run] ${gl_repo_name} plan complete"
  elif [[ "$repo_failed" == true ]]; then
    FAILED=$((FAILED + 1))
    warn "${gl_repo_name} completed with failures"
  else
    SYNCED=$((SYNCED + 1))
    info "${gl_repo_name} synchronized successfully"
  fi
done

echo ""
if [[ "$DRY_RUN" == true ]]; then
  info "Complete — planned: ${PLANNED} | failed: ${FAILED}"
else
  info "Complete — synced: ${SYNCED} | failed: ${FAILED}"
fi
[[ "$FAILED" -eq 0 ]]
