#!/usr/bin/env bash
#
# Syncs the three pieroproietti GitLab forks from their GitHub upstreams.
# Mirrors all branches, tags, and creates GitLab Releases for any new tags.
#
# Repos synced:
#   github.com/pieroproietti/penguins-eggs      → openos-project/penguins-eggs_deving/penguins-eggs
#   github.com/pieroproietti/penguins-eggs-book → openos-project/penguins-eggs_deving/penguins-eggs-book
#   github.com/pieroproietti/oa-tools           → openos-project/penguins-eggs_deving/oa-tools
#
# Required CI variable:
#   GITLAB_TOKEN — PAT with api + write_repository scope
#
# Our local commits (CI files, docs) sit on branches that don't exist upstream
# (all-features, lts, feat/*, etc.) and are never touched by this script.
# Upstream branches (master, develop, main, devel) are force-updated to match
# upstream HEAD. Tags are pushed with --tags (no-op if already present).

set -uo pipefail

: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"

GL_API="https://gitlab.com/api/v4"

info()  { echo "[sync] $*"; }
warn()  { echo "[warn] $*" >&2; }

# Repos: "github_path|gitlab_project_id|upstream_branches"
# Note: penguins-eggs-book upstream has been inactive since 2024-07-12.
# It is kept as a read-only snapshot; sync is disabled to avoid noise.
# Active docs live in penguins-eggs/docs/ instead.
# Note: oa-tools main is a clean upstream mirror; CI lives on openos/ci branch.
REPOS=(
  "pieroproietti/penguins-eggs|81413430|master develop"
  "pieroproietti/oa-tools|81412997|main devel"
)

SYNCED=0
FAILED=0

for entry in "${REPOS[@]}"; do
  gh_path="${entry%%|*}"; rest="${entry#*|}"
  gl_pid="${rest%%|*}"; upstream_branches="${rest##*|}"
  gl_repo_name="${gh_path##*/}"

  info "──────────────────────────────────────────"
  info "Syncing ${gh_path} → project ${gl_pid}"

  # Get GitLab repo URL
  gl_url=$(curl -sf --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${GL_API}/projects/${gl_pid}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['http_url_to_repo'])" 2>/dev/null)

  if [ -z "$gl_url" ]; then
    warn "Could not fetch GitLab URL for project ${gl_pid} — skipping"
    FAILED=$((FAILED + 1))
    continue
  fi

  gl_auth_url="${gl_url/https:\/\//https://oauth2:${GITLAB_TOKEN}@}"
  gh_url="https://github.com/${gh_path}.git"

  work_dir=$(mktemp -d)
  trap 'rm -rf "$work_dir"' RETURN

  # Clone mirror from GitHub
  info "Cloning ${gh_url} ..."
  if ! git clone --mirror "$gh_url" "$work_dir/mirror" 2>&1 | grep -v "^$"; then
    warn "Clone failed for ${gh_path}"
    FAILED=$((FAILED + 1))
    rm -rf "$work_dir"
    continue
  fi

  cd "$work_dir/mirror"

  # Push all refs (branches + tags) to GitLab
  # --prune would delete our local-only branches, so we push selectively:
  # 1. All tags (safe — additive only)
  info "Pushing tags ..."
  git push "$gl_auth_url" --tags 2>&1 | grep -v "^$" || true

  # 2. Upstream branches only (force to match upstream HEAD)
  for branch in $upstream_branches; do
    ref="refs/heads/${branch}"
    if git show-ref --verify --quiet "$ref" 2>/dev/null; then
      info "Pushing branch ${branch} ..."
      git push "$gl_auth_url" "+${ref}:${ref}" 2>&1 | grep -v "^$" || true
    else
      info "Branch ${branch} not found in upstream — skipping"
    fi
  done

  # 3. Create GitLab Releases for any new tags that have GitHub release notes
  info "Syncing releases ..."
  gh_releases=$(curl -sf "https://api.github.com/repos/${gh_path}/releases?per_page=100" 2>/dev/null || echo "[]")
  gl_releases=$(curl -sf --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${GL_API}/projects/${gl_pid}/releases?per_page=100" 2>/dev/null || echo "[]")

  existing_tags=$(echo "$gl_releases" | python3 -c \
    "import sys,json; [print(r['tag_name']) for r in json.load(sys.stdin)]" 2>/dev/null || true)

  echo "$gh_releases" | python3 - << 'PYEOF'
import sys, json, os, urllib.request, urllib.error

releases = json.load(sys.stdin)
token = os.environ.get("GITLAB_TOKEN", "")
api = os.environ.get("GL_API", "")
pid = os.environ.get("GL_PID", "")
gh_path = os.environ.get("GH_PATH", "")
existing = set(os.environ.get("EXISTING_TAGS", "").splitlines())

for r in releases:
    tag = r["tag_name"]
    if tag in existing:
        print(f"  release {tag} already exists — skip")
        continue
    name = r.get("name") or tag
    body = r.get("body") or ""
    published = r["published_at"]
    desc = (
        f"> Mirrored from [{gh_path} {tag}]"
        f"(https://github.com/{gh_path}/releases/tag/{tag})\n\n{body}"
    )
    payload = json.dumps({
        "name": name, "tag_name": tag,
        "description": desc, "released_at": published,
    }).encode()
    req = urllib.request.Request(
        f"{api}/projects/{pid}/releases",
        data=payload,
        headers={"PRIVATE-TOKEN": token, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as resp:
            d = json.load(resp)
            print(f"  ✅ release {tag}")
    except urllib.error.HTTPError as e:
        body_err = e.read().decode()
        if "already exists" in body_err or "already been taken" in body_err:
            print(f"  release {tag} already exists — skip")
        else:
            print(f"  ⚠️  release {tag}: HTTP {e.code} {body_err[:100]}")
PYEOF

  cd /
  rm -rf "$work_dir"
  trap - RETURN

  info "✅ ${gl_repo_name} done"
  SYNCED=$((SYNCED + 1))
done

echo ""
info "Complete — synced: ${SYNCED} | failed: ${FAILED}"
[ "$FAILED" -eq 0 ] || exit 1
