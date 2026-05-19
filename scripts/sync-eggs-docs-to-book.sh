#!/usr/bin/env bash
#
# Syncs docs/ from penguins-eggs (all-features branch) into penguins-eggs-book.
#
# Triggered by the sync-eggs-docs-to-book CI job, which is itself triggered
# via a pipeline trigger from penguins-eggs when docs/ changes.
#
# Required CI variables:
#   GITLAB_TOKEN  — PAT with api + write_repository scope
#
# Optional:
#   EGGS_REF      — penguins-eggs branch/tag to sync from (default: all-features)
#   EGGS_SHA      — short SHA for the commit message (set by trigger payload)
#
set -uo pipefail

: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"

EGGS_REF="${EGGS_REF:-all-features}"
EGGS_SHA="${EGGS_SHA:-}"

EGGS_REPO="https://oauth2:${GITLAB_TOKEN}@gitlab.com/openos-project/penguins-eggs_deving/penguins-eggs.git"
BOOK_REPO="https://oauth2:${GITLAB_TOKEN}@gitlab.com/openos-project/penguins-eggs_deving/penguins-eggs-book.git"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "Cloning penguins-eggs @ ${EGGS_REF} …"
git clone --depth=1 --branch "${EGGS_REF}" --filter=blob:none --sparse \
  "${EGGS_REPO}" "${WORKDIR}/eggs"
git -C "${WORKDIR}/eggs" sparse-checkout set docs

echo "Cloning penguins-eggs-book …"
git clone --depth=1 "${BOOK_REPO}" "${WORKDIR}/book"

echo "Copying docs/ into book …"
for dir in "${WORKDIR}/eggs/docs/"/*/; do
  [ -d "$dir" ] || continue
  topic=$(basename "$dir")
  mkdir -p "${WORKDIR}/book/${topic}"
  cp -r "${dir}." "${WORKDIR}/book/${topic}/"
done

EGGS_HEAD=$(git -C "${WORKDIR}/eggs" rev-parse --short HEAD)
echo "Synced docs/ from penguins-eggs @ ${EGGS_HEAD}"

cd "${WORKDIR}/book" || exit 1
git config user.email "sync-bot@gitlab.com"
git config user.name "Sync Bot"
git add .

if git diff --cached --quiet; then
  echo "No changes — docs already up to date."
  exit 0
fi

MSG="sync: update docs from penguins-eggs"
if [ -n "${EGGS_SHA}" ]; then
  MSG="${MSG} (${EGGS_SHA:0:7})"
else
  MSG="${MSG} (${EGGS_HEAD})"
fi

git commit -m "${MSG}"
git push
echo "Pushed updated docs to penguins-eggs-book."
