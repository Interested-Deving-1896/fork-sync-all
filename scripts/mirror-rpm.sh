#!/usr/bin/env bash
#
# Mirror RPM packages to a self-hosted RPM repo on GitHub Pages.
#
# For each repo in OSP/OOC that has .rpm assets in its GitHub Release:
#   1. Download .rpm files from the upstream release
#   2. Add them to a createrepo-managed RPM repo
#   3. Push the repo metadata to gh-pages of a dedicated rpm-repo repository
#
# Users add the repo with:
#   sudo curl -o /etc/yum.repos.d/osp.repo \
#     https://openOS-project-osp.github.io/rpm-repo/osp.repo
#
# Requires: GH_TOKEN, UPSTREAM_OWNER, TARGET_ORG, UPSTREAM_REPO, RELEASE_TAG
# Requires: createrepo_c (installed on runner)
#
set -uo pipefail

: "${GH_TOKEN:?required}"
: "${UPSTREAM_OWNER:?required}"
: "${TARGET_ORG:?required}"
: "${UPSTREAM_REPO:?required}"
: "${RELEASE_TAG:?required}"

API="https://api.github.com"
AUTH=(-H "Authorization: token ${GH_TOKEN}" -H "Accept: application/vnd.github+json")
RPM_REPO_NAME="rpm-repo"
PAGES_BRANCH="gh-pages"

api_get() { curl --disable --silent "${AUTH[@]}" "$@"; }

to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

echo "Mirroring RPM: ${UPSTREAM_OWNER}/${UPSTREAM_REPO}@${RELEASE_TAG} -> ${TARGET_ORG}"

# 1. Find .rpm assets in upstream release
release=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/releases/tags/${RELEASE_TAG}")
rpm_urls=$(echo "$release" | jq -r '.assets[] | select(.name | endswith(".rpm")) | .browser_download_url')

if [[ -z "$rpm_urls" ]]; then
  echo "No .rpm assets found in release ${RELEASE_TAG} — skipping."
  exit 0
fi

# 2. Ensure rpm-repo exists in TARGET_ORG
repo_check=$(api_get "${API}/repos/${TARGET_ORG}/${RPM_REPO_NAME}")
if ! echo "$repo_check" | jq -e '.id' > /dev/null 2>&1; then
  echo "  Creating ${TARGET_ORG}/${RPM_REPO_NAME}..."
  curl --disable --silent -X POST \
    "${AUTH[@]}" -H "Content-Type: application/json" \
    "${API}/orgs/${TARGET_ORG}/repos" \
    -d "{\"name\":\"${RPM_REPO_NAME}\",\"description\":\"Self-hosted RPM repository for ${TARGET_ORG}\",\"has_pages\":true,\"auto_init\":true}"
fi

# 3. Clone gh-pages
tmpdir=$(mktemp -d)
trap "rm -rf '$tmpdir'" EXIT

git clone --branch "$PAGES_BRANCH" --depth 1 \
  "https://x-access-token:${GH_TOKEN}@github.com/${TARGET_ORG}/${RPM_REPO_NAME}.git" \
  "${tmpdir}/pages" 2>/dev/null || {
  mkdir -p "${tmpdir}/pages"
  cd "${tmpdir}/pages"
  git init
  git checkout --orphan "$PAGES_BRANCH"
  git config user.email "ci@github.com"
  git config user.name "CI"
  touch .nojekyll
  git add .nojekyll
  git commit -m "init: create gh-pages for RPM repo"
  git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/${TARGET_ORG}/${RPM_REPO_NAME}.git"
  cd -
}

PACKAGES_DIR="${tmpdir}/pages/packages"
mkdir -p "$PACKAGES_DIR"

# 4. Download RPMs
while IFS= read -r url; do
  [[ -z "$url" ]] && continue
  fname=$(basename "$url")
  echo "  Downloading: $fname"
  curl --disable --silent -L -H "Authorization: token ${GH_TOKEN}" \
    -o "${PACKAGES_DIR}/${fname}" "$url"
done <<< "$rpm_urls"

# 5. Generate repo metadata
createrepo_c --update "${tmpdir}/pages"

# 6. Write .repo file for easy user setup
ORG_LOWER=$(to_lower "$TARGET_ORG")
cat > "${tmpdir}/pages/${ORG_LOWER}.repo" << REPOEOF
[${ORG_LOWER}]
name=${TARGET_ORG} RPM Repository
baseurl=https://${ORG_LOWER}.github.io/${RPM_REPO_NAME}
enabled=1
gpgcheck=0
REPOEOF

# 7. Commit and push
cd "${tmpdir}/pages"
git config user.email "ci@github.com"
git config user.name "CI"
git add -A
git commit -m "rpm: mirror ${UPSTREAM_REPO} ${RELEASE_TAG} from ${UPSTREAM_OWNER} [auto]" || \
  echo "  Nothing changed in RPM repo."
git push origin "$PAGES_BRANCH"

echo "  RPM repo updated: https://${ORG_LOWER}.github.io/${RPM_REPO_NAME}"
echo "  Install with:"
echo "    sudo curl -o /etc/yum.repos.d/${ORG_LOWER}.repo https://${ORG_LOWER}.github.io/${RPM_REPO_NAME}/${ORG_LOWER}.repo"
