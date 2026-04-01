#!/usr/bin/env bash
#
# Build and publish a self-hosted Flatpak repo on GitHub Pages.
#
# For each repo in OSP/OOC that has a Flatpak manifest:
#   1. Download the Flatpak bundle from the upstream GitHub Release
#   2. Import it into a local ostree repo
#   3. Push the ostree repo to the gh-pages branch of a dedicated
#      flatpak-repo repository in the org
#
# The flatpak-repo GitHub Pages site acts as a Flatpak remote.
# Users add it with:
#   flatpak remote-add --if-not-exists osp \
#     https://openOS-project-osp.github.io/flatpak-repo
#
# Requires: GH_TOKEN, UPSTREAM_OWNER, TARGET_ORG, UPSTREAM_REPO, RELEASE_TAG
# Requires: flatpak, flatpak-builder, ostree (installed on runner)
#
set -uo pipefail

: "${GH_TOKEN:?required}"
: "${UPSTREAM_OWNER:?required}"
: "${TARGET_ORG:?required}"
: "${UPSTREAM_REPO:?required}"
: "${RELEASE_TAG:?required}"

API="https://api.github.com"
AUTH=(-H "Authorization: token ${GH_TOKEN}" -H "Accept: application/vnd.github+json")
FLATPAK_REPO_NAME="flatpak-repo"
PAGES_BRANCH="gh-pages"

api_get() { curl --disable --silent "${AUTH[@]}" "$@"; }

echo "Mirroring Flatpak: ${UPSTREAM_OWNER}/${UPSTREAM_REPO}@${RELEASE_TAG} -> ${TARGET_ORG}"

# 1. Find .flatpak bundle in upstream release assets
release=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/releases/tags/${RELEASE_TAG}")
bundle_url=$(echo "$release" | jq -r '.assets[] | select(.name | endswith(".flatpak")) | .browser_download_url' | head -1)

if [[ -z "$bundle_url" ]]; then
  echo "No .flatpak bundle found in release ${RELEASE_TAG} — skipping."
  exit 0
fi

bundle_name=$(basename "$bundle_url")
echo "  Downloading: $bundle_name"
curl --disable --silent -L -H "Authorization: token ${GH_TOKEN}" \
  -o "/tmp/${bundle_name}" "$bundle_url"

# 2. Ensure flatpak-repo exists in TARGET_ORG (create if missing)
repo_check=$(api_get "${API}/repos/${TARGET_ORG}/${FLATPAK_REPO_NAME}")
if echo "$repo_check" | jq -e '.id' > /dev/null 2>&1; then
  echo "  flatpak-repo exists in ${TARGET_ORG}"
else
  echo "  Creating ${TARGET_ORG}/${FLATPAK_REPO_NAME}..."
  curl --disable --silent -X POST \
    "${AUTH[@]}" -H "Content-Type: application/json" \
    "${API}/orgs/${TARGET_ORG}/repos" \
    -d "{\"name\":\"${FLATPAK_REPO_NAME}\",\"description\":\"Self-hosted Flatpak repository for ${TARGET_ORG}\",\"has_pages\":true,\"auto_init\":true}"
fi

# 3. Clone or init the ostree repo from gh-pages
tmpdir=$(mktemp -d)
trap "rm -rf '$tmpdir'" EXIT

git clone --branch "$PAGES_BRANCH" --depth 1 \
  "https://x-access-token:${GH_TOKEN}@github.com/${TARGET_ORG}/${FLATPAK_REPO_NAME}.git" \
  "${tmpdir}/pages" 2>/dev/null || {
  # gh-pages doesn't exist yet — create orphan branch
  mkdir -p "${tmpdir}/pages"
  cd "${tmpdir}/pages"
  git init
  git checkout --orphan "$PAGES_BRANCH"
  git config user.email "ci@github.com"
  git config user.name "CI"
  touch .nojekyll
  git add .nojekyll
  git commit -m "init: create gh-pages for Flatpak repo"
  git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/${TARGET_ORG}/${FLATPAK_REPO_NAME}.git"
  cd -
}

# 4. Import bundle into ostree repo
OSTREE_REPO="${tmpdir}/pages/repo"
if [[ ! -d "$OSTREE_REPO" ]]; then
  ostree init --mode=archive-z2 --repo="$OSTREE_REPO"
fi

flatpak build-import-bundle "$OSTREE_REPO" "/tmp/${bundle_name}"

# 5. Generate appstream and icons
flatpak build-update-repo \
  --generate-static-deltas \
  --prune \
  "$OSTREE_REPO"

# 6. Commit and push to gh-pages
cd "${tmpdir}/pages"
git config user.email "ci@github.com"
git config user.name "CI"
git add -A
git commit -m "flatpak: mirror ${UPSTREAM_REPO} ${RELEASE_TAG} from ${UPSTREAM_OWNER} [auto]" || \
  echo "  Nothing changed in Flatpak repo."
git push origin "$PAGES_BRANCH"

echo "  Flatpak repo updated: https://${TARGET_ORG,,}.github.io/${FLATPAK_REPO_NAME}"
