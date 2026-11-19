#!/usr/bin/env bash
#
# scripts/upload-asset.sh — agnostic asset uploader for fork-sync-all
#
# Accepts files from three source types and delivers them to one of four
# destinations within Interested-Deving-1896/fork-sync-all.
#
# ── Source types ──────────────────────────────────────────────────────────────
#
#   url:<URL>          — download from a public or authenticated URL
#   artifact:<name>    — download from a prior GitHub Actions run artifact
#   repo:<path>        — file already present in the checked-out repo
#
# Multiple sources may be passed as space-separated values.
#
# ── Destination types ─────────────────────────────────────────────────────────
#
#   release:<tag>      — attach as a GitHub Release asset (creates release if absent)
#   commit:<dir>       — commit into the repo tree at <dir> (creates dir if absent)
#   comment:<issue>    — post as a base64-embedded link in an issue/PR comment
#                        (GitHub does not support binary attachments via API;
#                         the file is uploaded to a release stub and linked)
#   release-auto       — like release:<tag> but auto-generates tag from date+slug
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   bash scripts/upload-asset.sh \
#     --sources "url:https://example.com/file.pdf repo:DOCS/arch.png" \
#     --dest    "commit:assets/uploads" \
#     --repo    "Interested-Deving-1896/fork-sync-all"
#
# Required env vars:
#   GH_TOKEN   — PAT with contents:write (and actions:read for artifact source)
#   REPO       — owner/repo (default: Interested-Deving-1896/fork-sync-all)
#
# Optional env vars:
#   RUN_ID     — Actions run ID to pull artifacts from (default: current run)
#   DRY_RUN    — set to "true" to skip writes
#   COMMIT_MSG — override commit message for commit: destination

set -uo pipefail

REPO="${REPO:-Interested-Deving-1896/fork-sync-all}"
DRY_RUN="${DRY_RUN:-false}"
RUN_ID="${RUN_ID:-}"
COMMIT_MSG="${COMMIT_MSG:-}"
API="https://api.github.com"

info() { echo "[upload-asset] $*" >&2; }
warn() { echo "[upload-asset] ⚠  $*" >&2; }
ok()   { echo "[upload-asset] ✓ $*" >&2; }
fail() { echo "[upload-asset] ✗ $*" >&2; exit 1; }
dry()  { echo "[upload-asset] [dry-run] $*" >&2; }

# ── Arg parsing ───────────────────────────────────────────────────────────────
SOURCES=""
DEST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sources|-s) SOURCES="$2"; shift 2 ;;
    --dest|-d)    DEST="$2";    shift 2 ;;
    --repo|-r)    REPO="$2";    shift 2 ;;
    --dry-run)    DRY_RUN="true"; shift ;;
    --run-id)     RUN_ID="$2";  shift 2 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -z "$SOURCES" ]] && fail "--sources is required"
[[ -z "$DEST"    ]] && fail "--dest is required"

# ── Workdir ───────────────────────────────────────────────────────────────────
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
info "Working directory: ${WORKDIR}"

# ── Resolve sources → local files ─────────────────────────────────────────────
declare -a LOCAL_FILES=()

for src in $SOURCES; do
  type="${src%%:*}"
  value="${src#*:}"

  case "$type" in

    url)
      filename=$(basename "${value%%\?*}")   # strip query string from filename
      [[ -z "$filename" || "$filename" == "/" ]] && filename="download-$(date +%s)"
      dest_file="${WORKDIR}/${filename}"
      info "Downloading: ${value}"
      if [[ "$DRY_RUN" == "true" ]]; then
        dry "Would curl -fsSL '${value}' -o '${dest_file}'"
        touch "$dest_file"   # placeholder for dry-run path tracking
      else
        if ! curl -fsSL \
          -H "Authorization: token ${GH_TOKEN}" \
          "${value}" -o "${dest_file}" 2>/dev/null; then
          # Retry without auth header (public URL)
          curl -fsSL "${value}" -o "${dest_file}" \
            || fail "Failed to download: ${value}"
        fi
        ok "Downloaded: ${filename} ($(du -sh "$dest_file" | cut -f1))"
      fi
      LOCAL_FILES+=("$dest_file")
      ;;

    artifact)
      artifact_name="$value"
      info "Downloading artifact: ${artifact_name}"
      artifact_dir="${WORKDIR}/artifact-${artifact_name}"
      mkdir -p "$artifact_dir"
      if [[ "$DRY_RUN" == "true" ]]; then
        dry "Would gh run download ${RUN_ID:+--run-id $RUN_ID} --name '${artifact_name}' --dir '${artifact_dir}'"
        touch "${artifact_dir}/placeholder"
      else
        gh_args=(run download)
        [[ -n "$RUN_ID" ]] && gh_args+=(--run-id "$RUN_ID")
        gh_args+=(--name "$artifact_name" --dir "$artifact_dir" --repo "$REPO")
        gh "${gh_args[@]}" || fail "Failed to download artifact: ${artifact_name}"
        ok "Downloaded artifact: ${artifact_name}"
      fi
      # Add all files from the artifact dir
      while IFS= read -r -d '' f; do
        LOCAL_FILES+=("$f")
      done < <(find "$artifact_dir" -type f -print0)
      ;;

    repo)
      repo_path="$value"
      # Path is relative to repo root — must exist in the checkout
      if [[ -f "$repo_path" ]]; then
        LOCAL_FILES+=("$repo_path")
        ok "Using repo file: ${repo_path}"
      elif [[ -d "$repo_path" ]]; then
        while IFS= read -r -d '' f; do
          LOCAL_FILES+=("$f")
        done < <(find "$repo_path" -type f -print0)
        ok "Using repo directory: ${repo_path} ($(find "$repo_path" -type f | wc -l) files)"
      else
        fail "Repo path not found: ${repo_path}"
      fi
      ;;

    *)
      fail "Unknown source type '${type}'. Use: url:<URL> | artifact:<name> | repo:<path>"
      ;;
  esac
done

if [[ ${#LOCAL_FILES[@]} -eq 0 ]]; then
  fail "No files resolved from sources"
fi

info "Resolved ${#LOCAL_FILES[@]} file(s) for upload:"
for f in "${LOCAL_FILES[@]}"; do
  size=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
  info "  $(basename "$f") (${size})"
done

# ── Deliver to destination ────────────────────────────────────────────────────
dest_type="${DEST%%:*}"
dest_value="${DEST#*:}"

case "$dest_type" in

  # ── GitHub Release asset ───────────────────────────────────────────────────
  release|release-auto)
    if [[ "$dest_type" == "release-auto" ]]; then
      # Auto-generate tag: assets-YYYY-MM-DD[-slug]
      slug=$(basename "${LOCAL_FILES[0]}" | sed 's/\.[^.]*$//' | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-*$//' | cut -c1-30)
      TAG="assets-$(date -u +%Y-%m-%d)-${slug}"
    else
      TAG="$dest_value"
    fi

    info "Destination: GitHub Release — ${TAG}"

    if [[ "$DRY_RUN" != "true" ]]; then
      # Create release if it doesn't exist
      if ! gh release view "$TAG" --repo "$REPO" > /dev/null 2>&1; then
        info "Creating release ${TAG}..."
        gh release create "$TAG" \
          --repo "$REPO" \
          --title "Assets — ${TAG}" \
          --notes "Asset upload via \`scripts/upload-asset.sh\`." \
          --prerelease
        ok "Release ${TAG} created."
      else
        info "Release ${TAG} already exists."
      fi

      failed=0
      for f in "${LOCAL_FILES[@]}"; do
        fname=$(basename "$f")
        info "Uploading ${fname} to release ${TAG}..."
        if gh release upload "$TAG" "$f" --repo "$REPO" --clobber; then
          ok "Uploaded: ${fname}"
          echo "  → https://github.com/${REPO}/releases/download/${TAG}/${fname}" >&2
        else
          warn "Failed to upload: ${fname}"
          (( failed++ )) || true
        fi
      done
      [[ "$failed" -gt 0 ]] && fail "${failed} file(s) failed to upload"
    else
      dry "Would create/update release '${TAG}' and upload ${#LOCAL_FILES[@]} file(s)"
    fi
    ;;

  # ── Commit into repo tree ──────────────────────────────────────────────────
  commit)
    target_dir="${dest_value}"
    info "Destination: repo commit — ${target_dir}/"

    if [[ "$DRY_RUN" != "true" ]]; then
      mkdir -p "$target_dir"
      copied=()
      for f in "${LOCAL_FILES[@]}"; do
        fname=$(basename "$f")
        cp "$f" "${target_dir}/${fname}"
        copied+=("${target_dir}/${fname}")
        ok "Copied: ${fname} → ${target_dir}/"
      done

      # Stage and commit
      git add "${copied[@]}"

      # Check if there's anything to commit
      if git diff --cached --quiet; then
        info "No changes to commit (files already up to date)."
      else
        msg="${COMMIT_MSG:-"chore(assets): upload ${#copied[@]} file(s) to ${target_dir}"}"
        git config --local user.name  "github-actions[bot]"
        git config --local user.email "github-actions[bot]@users.noreply.github.com"
        git commit -m "$msg"
        git push
        ok "Committed and pushed ${#copied[@]} file(s) to ${target_dir}/"
      fi
    else
      dry "Would mkdir -p '${target_dir}' and commit ${#LOCAL_FILES[@]} file(s)"
    fi
    ;;

  # ── Issue / PR comment (via release stub link) ─────────────────────────────
  comment)
    issue_number="$dest_value"
    info "Destination: issue/PR comment — #${issue_number}"

    # GitHub's API does not support binary file attachments in comments.
    # Strategy: upload to a stub release, then post the download URLs as a comment.
    stub_tag="attachments-$(date -u +%Y-%m-%d)"

    if [[ "$DRY_RUN" != "true" ]]; then
      # Ensure stub release exists
      if ! gh release view "$stub_tag" --repo "$REPO" > /dev/null 2>&1; then
        gh release create "$stub_tag" \
          --repo "$REPO" \
          --title "Attachments — $(date -u +%Y-%m-%d)" \
          --notes "Auto-created stub release for issue/PR comment attachments." \
          --prerelease
      fi

      # Upload files to stub release
      links=()
      for f in "${LOCAL_FILES[@]}"; do
        fname=$(basename "$f")
        gh release upload "$stub_tag" "$f" --repo "$REPO" --clobber
        links+=("- [${fname}](https://github.com/${REPO}/releases/download/${stub_tag}/${fname})")
        ok "Uploaded: ${fname}"
      done

      # Post comment
      body="**Attached files** (uploaded via \`upload-asset.sh\`):"$'\n'"$(printf '%s\n' "${links[@]}")"
      gh issue comment "$issue_number" --repo "$REPO" --body "$body"
      ok "Posted comment on #${issue_number}"
    else
      dry "Would upload ${#LOCAL_FILES[@]} file(s) to stub release '${stub_tag}' and comment on #${issue_number}"
    fi
    ;;

  *)
    fail "Unknown destination type '${dest_type}'. Use: release:<tag> | release-auto | commit:<dir> | comment:<issue>"
    ;;
esac

info "Done."
