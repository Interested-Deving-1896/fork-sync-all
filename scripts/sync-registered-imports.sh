#!/usr/bin/env bash
#
# Re-syncs all repos registered in registered-imports.json.
#
# For each entry, bare-clones the source URL and pushes all branches + tags
# to the Interested-Deving-1896 counterpart. Platform-specific tokens are
# used automatically when available.
#
# registered-imports.json schema (array of objects):
#   {
#     "source_url":  "https://gitlab.com/some-group/some-repo",
#     "target_name": "some-repo",
#     "platform":    "gitlab",
#     "added":       "2026-05-02T18:00:00Z"
#   }
#
# Required env vars:
#   GH_TOKEN      — GitHub PAT (repo + workflow scopes)
#   GITHUB_OWNER  — Interested-Deving-1896
#
# Optional env vars (for private sources):
#   GITLAB_TOKEN      — GitLab PAT with read_repository scope
#   BITBUCKET_TOKEN   — Bitbucket app password
#   GITEA_TOKEN       — Gitea PAT

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_OWNER:=Interested-Deving-1896}"

IMPORTS_FILE="registered-imports.json"

info() { echo "[sync-registered-imports] $*"; }
warn() { echo "[warn] $*" >&2; }

sanitize() {
  local out="$1"
  echo "$out" \
    | sed "s/${GH_TOKEN}/***TOKEN***/g" \
    | sed "s/${GITLAB_TOKEN:-NOGLTOKEN}/***TOKEN***/g" \
    | sed "s/${BITBUCKET_TOKEN:-NOBBTOKEN}/***TOKEN***/g" \
    | sed "s/${GITEA_TOKEN:-NOGTTOKEN}/***TOKEN***/g"
}

# Build authenticated clone URL for a given source URL + platform
auth_clone_url() {
  local url="$1" platform="$2"
  case "$platform" in
    github)
      echo "${url/https:\/\//https://x-access-token:${GH_TOKEN}@}.git"
      ;;
    gitlab)
      if [ -n "${GITLAB_TOKEN:-}" ]; then
        echo "${url/https:\/\//https://oauth2:${GITLAB_TOKEN}@}.git"
      else
        echo "${url}.git"
      fi
      ;;
    bitbucket)
      if [ -n "${BITBUCKET_TOKEN:-}" ]; then
        echo "${url/https:\/\/bitbucket.org\//https://x-token-auth:${BITBUCKET_TOKEN}@bitbucket.org/}.git"
      else
        echo "${url}.git"
      fi
      ;;
    gitea)
      if [ -n "${GITEA_TOKEN:-}" ]; then
        echo "${url/https:\/\//https://x-access-token:${GITEA_TOKEN}@}.git"
      else
        echo "${url}.git"
      fi
      ;;
    *)
      echo "${url}.git"
      ;;
  esac
}

sync_entry() {
  local source_url="$1" target_name="$2" platform="$3"

  info "──────────────────────────────────────────"
  info "${source_url}  →  github.com/${GITHUB_OWNER}/${target_name}"

  local clone_url
  clone_url=$(auth_clone_url "$source_url" "$platform")

  local work_dir
  work_dir=$(mktemp -d)

  # Clone
  if ! git clone --mirror "$clone_url" "$work_dir" 2>&1 | sanitize "$clone_url"; then
    warn "Clone failed for ${source_url} — skipping"
    rm -rf "$work_dir"
    return 1
  fi

  cd "$work_dir"

  local gh_url="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_OWNER}/${target_name}.git"
  local push_ok=true

  # Push branches (no prune — preserves GitHub-only branches)
  git push "$gh_url" '+refs/heads/*:refs/heads/*' 2>&1 \
    | sed "s/${GH_TOKEN}/***TOKEN***/g" \
    || push_ok=false

  # Push tags (non-fatal)
  git push "$gh_url" '+refs/tags/*:refs/tags/*' 2>&1 \
    | sed "s/${GH_TOKEN}/***TOKEN***/g" \
    || true

  cd /
  rm -rf "$work_dir"

  if $push_ok; then
    info "✅ ${target_name} done"
    return 0
  else
    warn "❌ ${target_name} push failed"
    return 1
  fi
}

# ── main ─────────────────────────────────────────────────────────────────────

if [ ! -f "$IMPORTS_FILE" ]; then
  info "No ${IMPORTS_FILE} found — nothing to sync."
  exit 0
fi

entry_count=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$IMPORTS_FILE" 2>/dev/null || echo 0)

if [ "$entry_count" -eq 0 ]; then
  info "registered-imports.json is empty — nothing to sync."
  exit 0
fi

info "Found ${entry_count} registered import(s)."
echo ""

synced=0
failed=0

# Iterate entries via python3 to handle JSON safely
while IFS='|' read -r source_url target_name platform; do
  [ -z "$source_url" ] && continue
  if sync_entry "$source_url" "$target_name" "$platform"; then
    synced=$((synced + 1))
  else
    failed=$((failed + 1))
  fi
done < <(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
for e in data:
    print('%s|%s|%s' % (e['source_url'], e['target_name'], e.get('platform','generic')))
" "$IMPORTS_FILE")

echo ""
info "Complete — synced: ${synced} | failed: ${failed}"
[ "$failed" -eq 0 ] || exit 1
