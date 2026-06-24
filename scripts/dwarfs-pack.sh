#!/usr/bin/env bash
#
# dwarfs-pack.sh — scan, pack, and prune release artifacts using DwarFS
#
# Called by .github/workflows/dwarfs-pack-release.yml in three modes:
#
#   --scan   Find files in asset_dir >= threshold_mb; write GitHub Actions
#            output vars (has_candidates, candidate_count, candidate_bytes)
#
#   --pack   Build a DwarFS image from asset_dir, zip it, write checksums.
#            Output goes to /tmp/dwarfs-out/
#
#   --prune  Delete original oversized release assets from the GitHub Release
#            via gh CLI (only runs when prune_originals: true)
#
# All modes share the same --asset-dir and --threshold flags.

set -uo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────

MODE=""
ASSET_DIR="release-assets"
THRESHOLD_MB=50
IMAGE_NAME=""
ZSTD_LEVEL=9
OUTPUT_ENV=""
RELEASE_TAG=""
REPO=""

# ── Argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scan)         MODE="scan";           shift ;;
    --pack)         MODE="pack";           shift ;;
    --prune)        MODE="prune";          shift ;;
    --asset-dir)    ASSET_DIR="$2";        shift 2 ;;
    --threshold)    THRESHOLD_MB="$2";     shift 2 ;;
    --image-name)   IMAGE_NAME="$2";       shift 2 ;;
    --zstd-level)   ZSTD_LEVEL="$2";       shift 2 ;;
    --output-env)   OUTPUT_ENV="$2";       shift 2 ;;
    --release-tag)  RELEASE_TAG="$2";      shift 2 ;;
    --repo)         REPO="$2";             shift 2 ;;
    *) echo "[dwarfs-pack] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$MODE" ]] || { echo "[dwarfs-pack] ERROR: mode required (--scan | --pack | --prune)" >&2; exit 1; }

THRESHOLD_BYTES=$(( THRESHOLD_MB * 1024 * 1024 ))

# ── Helpers ───────────────────────────────────────────────────────────────────

info()  { echo "[dwarfs-pack] $*"; }
warn()  { echo "[dwarfs-pack] WARN: $*" >&2; }
error() { echo "[dwarfs-pack] ERROR: $*" >&2; }

emit() {
  # Write key=value to OUTPUT_ENV (GITHUB_OUTPUT) and stdout
  local kv="$1"
  echo "$kv"
  [[ -n "$OUTPUT_ENV" ]] && echo "$kv" >> "$OUTPUT_ENV"
}

# ── Mode: scan ────────────────────────────────────────────────────────────────

do_scan() {
  if [[ ! -d "$ASSET_DIR" ]]; then
    warn "asset_dir '${ASSET_DIR}' does not exist — nothing to scan"
    emit "has_candidates=false"
    emit "candidate_count=0"
    emit "candidate_bytes=0"
    return 0
  fi

  # Find files at or above threshold
  mapfile -t candidates < <(
    find "$ASSET_DIR" -type f -size +"${THRESHOLD_MB}M" | sort
  )

  local count=${#candidates[@]}

  if [[ $count -eq 0 ]]; then
    info "No files >= ${THRESHOLD_MB} MB in '${ASSET_DIR}' — skipping pack"
    emit "has_candidates=false"
    emit "candidate_count=0"
    emit "candidate_bytes=0"
    return 0
  fi

  # Sum total bytes
  local total_bytes=0
  for f in "${candidates[@]}"; do
    local sz
    sz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
    total_bytes=$(( total_bytes + sz ))
  done

  info "Found ${count} file(s) >= ${THRESHOLD_MB} MB ($(numfmt --to=iec-i --suffix=B "$total_bytes" 2>/dev/null || echo "${total_bytes} bytes")):"
  for f in "${candidates[@]}"; do
    local sz
    sz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
    info "  $(basename "$f")  ($(numfmt --to=iec-i --suffix=B "$sz" 2>/dev/null || echo "${sz} bytes"))"
  done

  emit "has_candidates=true"
  emit "candidate_count=${count}"
  emit "candidate_bytes=${total_bytes}"
}

# ── Mode: pack ────────────────────────────────────────────────────────────────

do_pack() {
  [[ -n "$IMAGE_NAME" ]] || { error "--image-name is required for --pack"; exit 1; }
  [[ -d "$ASSET_DIR" ]]  || { error "asset_dir '${ASSET_DIR}' does not exist"; exit 1; }

  command -v mkdwarfs >/dev/null 2>&1 || { error "mkdwarfs not found — install it first"; exit 1; }

  local out_dir="/tmp/dwarfs-out"
  mkdir -p "$out_dir"

  local dwarfs_file="${out_dir}/${IMAGE_NAME}.dwarfs"
  local zip_file="${out_dir}/${IMAGE_NAME}.dwarfs.zip"
  local sha_file="${out_dir}/${IMAGE_NAME}.dwarfs.zip.sha256"

  info "Building DwarFS image from '${ASSET_DIR}' (zstd level ${ZSTD_LEVEL})..."
  mkdwarfs \
    --input  "$ASSET_DIR" \
    --output "$dwarfs_file" \
    --compression "zstd:level=${ZSTD_LEVEL}" \
    --progress none \
    --log-level warn

  local dwarfs_size
  dwarfs_size=$(stat -c%s "$dwarfs_file" 2>/dev/null || stat -f%z "$dwarfs_file")
  info "DwarFS image: $(numfmt --to=iec-i --suffix=B "$dwarfs_size" 2>/dev/null || echo "${dwarfs_size} bytes")"

  info "Zipping DwarFS image..."
  zip -j "$zip_file" "$dwarfs_file"

  local zip_size
  zip_size=$(stat -c%s "$zip_file" 2>/dev/null || stat -f%z "$zip_file")
  info "Zip archive: $(numfmt --to=iec-i --suffix=B "$zip_size" 2>/dev/null || echo "${zip_size} bytes")"

  # Checksums for both the raw image and the zip
  (cd "$out_dir" && sha256sum "$(basename "$dwarfs_file")" "$(basename "$zip_file")") > "$sha_file"
  info "SHA256:"
  cat "$sha_file"

  emit "dwarfs_file=${dwarfs_file}"
  emit "zip_file=${zip_file}"
  emit "sha_file=${sha_file}"
  emit "zip_size=${zip_size}"
}

# ── Mode: prune ───────────────────────────────────────────────────────────────

do_prune() {
  [[ -n "$RELEASE_TAG" ]] || { error "--release-tag is required for --prune"; exit 1; }
  [[ -n "$REPO" ]]        || { error "--repo is required for --prune"; exit 1; }
  command -v gh >/dev/null 2>&1 || { error "gh CLI not found"; exit 1; }

  if [[ ! -d "$ASSET_DIR" ]]; then
    warn "asset_dir '${ASSET_DIR}' does not exist — nothing to prune"
    return 0
  fi

  mapfile -t candidates < <(
    find "$ASSET_DIR" -type f -size +"${THRESHOLD_MB}M" -printf '%f\n' | sort
  )

  if [[ ${#candidates[@]} -eq 0 ]]; then
    info "No files >= ${THRESHOLD_MB} MB — nothing to prune"
    return 0
  fi

  info "Pruning ${#candidates[@]} original file(s) from release ${RELEASE_TAG}..."
  local pruned=0 failed=0
  for name in "${candidates[@]}"; do
    if gh release delete-asset "$RELEASE_TAG" "$name" \
        --repo "$REPO" --yes 2>/dev/null; then
      info "  deleted: ${name}"
      pruned=$(( pruned + 1 ))
    else
      warn "  could not delete: ${name} (may not exist as release asset)"
      failed=$(( failed + 1 ))
    fi
  done
  info "Pruned ${pruned} asset(s), ${failed} skipped/failed"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "$MODE" in
  scan)  do_scan  ;;
  pack)  do_pack  ;;
  prune) do_prune ;;
esac
