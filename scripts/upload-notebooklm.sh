#!/usr/bin/env bash
#
# upload-notebooklm.sh
#
# Uploads NotebookLM generated output files to a GitHub Release asset.
# Creates the release if it doesn't exist yet.
#
# Usage:
#   bash scripts/upload-notebooklm.sh <tag> <file> [file2 ...]
#
# Examples:
#   bash scripts/upload-notebooklm.sh notebooklm-2026-06-09 ~/Downloads/overview.mp3
#   bash scripts/upload-notebooklm.sh notebooklm-2026-06-10 *.pdf *.mp3
#
# The tag must follow the pattern: notebooklm-YYYY-MM-DD
# The release is created as a pre-release if it doesn't exist.
#
# Required env vars (or gh CLI auth):
#   GH_TOKEN  — PAT with contents:write scope (falls back to gh auth token)
#
# Required tools: gh (GitHub CLI)

set -uo pipefail

REPO="${REPO:-Interested-Deving-1896/fork-sync-all}"

info() { echo "[upload-notebooklm] $*" >&2; }
warn() { echo "[upload-notebooklm] ⚠️  $*" >&2; }
ok()   { echo "[upload-notebooklm] ✓ $*" >&2; }
fail() { echo "[upload-notebooklm] ✗ $*" >&2; }

# ── Args ──────────────────────────────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <tag> <file> [file2 ...]" >&2
  echo "  tag  — release tag, e.g. notebooklm-2026-06-09" >&2
  echo "  file — one or more files to upload" >&2
  exit 1
fi

TAG="$1"
shift
FILES=("$@")

# Validate tag format
if [[ ! "$TAG" =~ ^notebooklm-[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  fail "Tag must match notebooklm-YYYY-MM-DD (got: ${TAG})"
  exit 1
fi

DATE="${TAG#notebooklm-}"

# ── Validate files ────────────────────────────────────────────────────────────
for f in "${FILES[@]}"; do
  if [[ ! -f "$f" ]]; then
    fail "File not found: ${f}"
    exit 1
  fi
done

info "Tag:   ${TAG}"
info "Repo:  ${REPO}"
info "Files: ${#FILES[@]}"
for f in "${FILES[@]}"; do
  size=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
  info "  ${f} (${size})"
done

# ── Ensure release exists ─────────────────────────────────────────────────────
if gh release view "$TAG" --repo "$REPO" > /dev/null 2>&1; then
  info "Release ${TAG} already exists — uploading to it."
else
  info "Creating release ${TAG}..."
  gh release create "$TAG" \
    --repo "$REPO" \
    --title "NotebookLM Generations — ${DATE}" \
    --notes "$(cat <<NOTES
## NotebookLM Generated Outputs — ${DATE}

Generated from the fork-sync-all documentation using [Google NotebookLM](https://notebooklm.google.com/).

See [docs/notebooklm/](https://github.com/${REPO}/tree/main/docs/notebooklm/) for the full index.

---
*Uploaded with \`scripts/upload-notebooklm.sh\`*
NOTES
)" \
    --prerelease
  ok "Release ${TAG} created."
fi

# ── Upload files ──────────────────────────────────────────────────────────────
failed=0
for f in "${FILES[@]}"; do
  filename=$(basename "$f")
  info "Uploading ${filename}..."
  if gh release upload "$TAG" "$f" \
    --repo "$REPO" \
    --clobber 2>/dev/null; then
    ok "Uploaded: ${filename}"
    echo "  → https://github.com/${REPO}/releases/download/${TAG}/${filename}" >&2
  else
    fail "Failed to upload: ${filename}"
    (( failed++ )) || true
  fi
done

# ── Update README index ───────────────────────────────────────────────────────
# Detect which subdirectory each file belongs to based on extension
# and print a reminder to update the README.md index.
echo "" >&2
info "Upload complete. Update the following README.md files with asset links:"
for f in "${FILES[@]}"; do
  filename=$(basename "$f")
  ext="${filename##*.}"
  case "$ext" in
    mp3|wav)  dir="audio-overview" ;;
    mp4)      dir="video-overview" ;;
    pptx|gslides) dir="slide-deck" ;;
    csv)      dir="flashcards" ;;
    pdf)
      # Heuristic: guess subdir from filename keywords
      lower="${filename,,}"
      if [[ "$lower" == *"slide"* || "$lower" == *"deck"* || "$lower" == *"presentation"* ]]; then
        dir="slide-deck"
      elif [[ "$lower" == *"flash"* || "$lower" == *"card"* ]]; then
        dir="flashcards"
      elif [[ "$lower" == *"quiz"* || "$lower" == *"question"* ]]; then
        dir="quiz"
      elif [[ "$lower" == *"infographic"* || "$lower" == *"visual"* ]]; then
        dir="infographic"
      else
        dir="reports"
      fi
      ;;
    png|jpg|jpeg) dir="infographic" ;;
    *)        dir="reports" ;;
  esac
  echo "  docs/notebooklm/${dir}/README.md  ←  ${filename}" >&2
done

[[ "$failed" -gt 0 ]] && exit 1
exit 0
