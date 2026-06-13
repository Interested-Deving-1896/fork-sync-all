#!/usr/bin/env bash
#
# generate-notebooklm.sh
#
# Generates NotebookLM content artifacts for a given notebook and uploads
# them to a GitHub Release via upload-notebooklm.sh.
#
# Requires notebooklm-py (pip install "notebooklm-py[browser]") and a
# pre-acquired auth state (NOTEBOOKLM_STORAGE_STATE or the default
# ~/.config/notebooklm/storage_state.json).
#
# Usage:
#   bash scripts/generate-notebooklm.sh [OPTIONS]
#
# Options:
#   --notebook-id ID      NotebookLM notebook ID (required)
#   --types TYPES         Comma-separated list of content types to generate.
#                         Supported: audio,video,slide-deck,infographic,
#                                    quiz,flashcards,report
#                         Default: all seven types
#   --release-tag TAG     GitHub Release tag to upload to (required).
#                         Must match notebooklm-YYYY-MM-DD.
#   --output-dir DIR      Local directory for downloaded artifacts.
#                         Default: /tmp/notebooklm-output
#   --dry-run             Print commands without executing them.
#   --skip-upload         Generate and download only; skip upload step.
#   --audio-format FMT    Audio format: deep-dive|brief|critique|debate
#                         Default: deep-dive
#   --video-format FMT    Video format: explainer|brief|cinematic
#                         Default: explainer
#   --report-format FMT   Report format: briefing-doc|study-guide|blog-post
#                         Default: briefing-doc
#
# Environment:
#   GH_TOKEN                   — PAT with contents:write (for upload)
#   NOTEBOOKLM_STORAGE_STATE   — path to notebooklm-py auth state JSON
#                                (default: ~/.config/notebooklm/storage_state.json)
#   REPO                       — target repo for upload (default: Interested-Deving-1896/fork-sync-all)

set -uo pipefail

# ── Logging ───────────────────────────────────────────────────────────────────
info() { echo "[generate-notebooklm] $*" >&2; }
warn() { echo "[generate-notebooklm] ⚠  $*" >&2; }
ok()   { echo "[generate-notebooklm] ✓ $*" >&2; }
fail() { echo "[generate-notebooklm] ✗ $*" >&2; }
dry()  { echo "[generate-notebooklm] [dry-run] $*" >&2; }

# ── Defaults ──────────────────────────────────────────────────────────────────
NOTEBOOK_ID=""
TYPES="audio,video,slide-deck,infographic,quiz,flashcards,report"
RELEASE_TAG=""
OUTPUT_DIR="/tmp/notebooklm-output"
DRY_RUN=false
SKIP_UPLOAD=false
AUDIO_FORMAT="deep-dive"
VIDEO_FORMAT="explainer"
REPORT_FORMAT="briefing-doc"
REPO="${REPO:-Interested-Deving-1896/fork-sync-all}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notebook-id)   NOTEBOOK_ID="$2";   shift 2 ;;
    --types)         TYPES="$2";         shift 2 ;;
    --release-tag)   RELEASE_TAG="$2";   shift 2 ;;
    --output-dir)    OUTPUT_DIR="$2";    shift 2 ;;
    --dry-run)       DRY_RUN=true;       shift ;;
    --skip-upload)   SKIP_UPLOAD=true;   shift ;;
    --audio-format)  AUDIO_FORMAT="$2";  shift 2 ;;
    --video-format)  VIDEO_FORMAT="$2";  shift 2 ;;
    --report-format) REPORT_FORMAT="$2"; shift 2 ;;
    *) fail "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────
if [[ -z "$NOTEBOOK_ID" ]]; then
  fail "--notebook-id is required"
  exit 1
fi

if [[ -z "$RELEASE_TAG" && "$SKIP_UPLOAD" == "false" ]]; then
  fail "--release-tag is required unless --skip-upload is set"
  exit 1
fi

if [[ -n "$RELEASE_TAG" && ! "$RELEASE_TAG" =~ ^notebooklm-[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  fail "--release-tag must match notebooklm-YYYY-MM-DD (got: ${RELEASE_TAG})"
  exit 1
fi

# ── Check notebooklm-py ───────────────────────────────────────────────────────
if ! command -v notebooklm &>/dev/null; then
  fail "notebooklm CLI not found. Install with: pip install 'notebooklm-py[browser]'"
  exit 1
fi

NLM_VERSION=$(notebooklm --version 2>/dev/null || echo "unknown")
info "notebooklm-py version: ${NLM_VERSION}"

# ── Auth state ────────────────────────────────────────────────────────────────
if [[ -n "${NOTEBOOKLM_STORAGE_STATE:-}" ]]; then
  if [[ ! -f "$NOTEBOOKLM_STORAGE_STATE" ]]; then
    fail "NOTEBOOKLM_STORAGE_STATE file not found: ${NOTEBOOKLM_STORAGE_STATE}"
    exit 1
  fi
  info "Auth state: ${NOTEBOOKLM_STORAGE_STATE}"
else
  DEFAULT_STATE="${HOME}/.config/notebooklm/storage_state.json"
  if [[ ! -f "$DEFAULT_STATE" ]]; then
    fail "No auth state found. Run 'notebooklm login' first, or set NOTEBOOKLM_STORAGE_STATE."
    exit 1
  fi
  info "Auth state: ${DEFAULT_STATE} (default)"
fi

# ── Setup output dir ──────────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"
info "Output dir: ${OUTPUT_DIR}"

# ── Helper: run or dry-run ────────────────────────────────────────────────────
run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    dry "$*"
  else
    "$@"
  fi
}

# ── Parse types list ──────────────────────────────────────────────────────────
IFS=',' read -ra TYPE_LIST <<< "$TYPES"
info "Types to generate: ${TYPE_LIST[*]}"
info "Notebook ID: ${NOTEBOOK_ID}"

# ── Track generated files for upload ─────────────────────────────────────────
GENERATED_FILES=()

# ── Generate + download each type ────────────────────────────────────────────
for type in "${TYPE_LIST[@]}"; do
  type="${type// /}"  # strip whitespace
  info "--- ${type} ---"

  case "$type" in

    audio)
      info "Generating audio overview (format: ${AUDIO_FORMAT})..."
      run_cmd notebooklm generate audio \
        --notebook-id "$NOTEBOOK_ID" \
        --format "$AUDIO_FORMAT" \
        --wait
      OUT="${OUTPUT_DIR}/audio-overview.mp3"
      run_cmd notebooklm download audio \
        --notebook-id "$NOTEBOOK_ID" \
        "$OUT"
      [[ "$DRY_RUN" == "false" && -f "$OUT" ]] && GENERATED_FILES+=("$OUT") && ok "Downloaded: ${OUT}"
      [[ "$DRY_RUN" == "true" ]] && GENERATED_FILES+=("$OUT")
      ;;

    video)
      info "Generating video overview (format: ${VIDEO_FORMAT})..."
      run_cmd notebooklm generate video \
        --notebook-id "$NOTEBOOK_ID" \
        --format "$VIDEO_FORMAT" \
        --wait
      OUT="${OUTPUT_DIR}/video-overview.mp4"
      run_cmd notebooklm download video \
        --notebook-id "$NOTEBOOK_ID" \
        "$OUT"
      [[ "$DRY_RUN" == "false" && -f "$OUT" ]] && GENERATED_FILES+=("$OUT") && ok "Downloaded: ${OUT}"
      [[ "$DRY_RUN" == "true" ]] && GENERATED_FILES+=("$OUT")
      ;;

    slide-deck)
      info "Generating slide deck..."
      run_cmd notebooklm generate slide-deck \
        --notebook-id "$NOTEBOOK_ID" \
        --wait
      OUT_PDF="${OUTPUT_DIR}/slide-deck.pdf"
      OUT_PPTX="${OUTPUT_DIR}/slide-deck.pptx"
      run_cmd notebooklm download slide-deck \
        --notebook-id "$NOTEBOOK_ID" \
        "$OUT_PDF"
      # Also attempt PPTX — may not always be available
      if run_cmd notebooklm download slide-deck \
          --notebook-id "$NOTEBOOK_ID" \
          --format pptx \
          "$OUT_PPTX" 2>/dev/null; then
        [[ "$DRY_RUN" == "false" && -f "$OUT_PPTX" ]] && GENERATED_FILES+=("$OUT_PPTX") && ok "Downloaded: ${OUT_PPTX}"
        [[ "$DRY_RUN" == "true" ]] && GENERATED_FILES+=("$OUT_PPTX")
      fi
      [[ "$DRY_RUN" == "false" && -f "$OUT_PDF" ]] && GENERATED_FILES+=("$OUT_PDF") && ok "Downloaded: ${OUT_PDF}"
      [[ "$DRY_RUN" == "true" ]] && GENERATED_FILES+=("$OUT_PDF")
      ;;

    infographic)
      info "Generating infographic..."
      run_cmd notebooklm generate infographic \
        --notebook-id "$NOTEBOOK_ID" \
        --wait
      OUT="${OUTPUT_DIR}/infographic.png"
      run_cmd notebooklm download infographic \
        --notebook-id "$NOTEBOOK_ID" \
        "$OUT"
      [[ "$DRY_RUN" == "false" && -f "$OUT" ]] && GENERATED_FILES+=("$OUT") && ok "Downloaded: ${OUT}"
      [[ "$DRY_RUN" == "true" ]] && GENERATED_FILES+=("$OUT")
      ;;

    quiz)
      info "Generating quiz..."
      run_cmd notebooklm generate quiz \
        --notebook-id "$NOTEBOOK_ID" \
        --wait
      OUT_JSON="${OUTPUT_DIR}/quiz.json"
      OUT_MD="${OUTPUT_DIR}/quiz.md"
      run_cmd notebooklm download quiz \
        --notebook-id "$NOTEBOOK_ID" \
        --format json \
        "$OUT_JSON"
      run_cmd notebooklm download quiz \
        --notebook-id "$NOTEBOOK_ID" \
        --format markdown \
        "$OUT_MD"
      [[ "$DRY_RUN" == "false" && -f "$OUT_JSON" ]] && GENERATED_FILES+=("$OUT_JSON") && ok "Downloaded: ${OUT_JSON}"
      [[ "$DRY_RUN" == "false" && -f "$OUT_MD"   ]] && GENERATED_FILES+=("$OUT_MD")   && ok "Downloaded: ${OUT_MD}"
      [[ "$DRY_RUN" == "true" ]] && GENERATED_FILES+=("$OUT_JSON" "$OUT_MD")
      ;;

    flashcards)
      info "Generating flashcards..."
      run_cmd notebooklm generate flashcards \
        --notebook-id "$NOTEBOOK_ID" \
        --wait
      OUT_JSON="${OUTPUT_DIR}/flashcards.json"
      OUT_MD="${OUTPUT_DIR}/flashcards.md"
      run_cmd notebooklm download flashcards \
        --notebook-id "$NOTEBOOK_ID" \
        --format json \
        "$OUT_JSON"
      run_cmd notebooklm download flashcards \
        --notebook-id "$NOTEBOOK_ID" \
        --format markdown \
        "$OUT_MD"
      [[ "$DRY_RUN" == "false" && -f "$OUT_JSON" ]] && GENERATED_FILES+=("$OUT_JSON") && ok "Downloaded: ${OUT_JSON}"
      [[ "$DRY_RUN" == "false" && -f "$OUT_MD"   ]] && GENERATED_FILES+=("$OUT_MD")   && ok "Downloaded: ${OUT_MD}"
      [[ "$DRY_RUN" == "true" ]] && GENERATED_FILES+=("$OUT_JSON" "$OUT_MD")
      ;;

    report)
      info "Generating report (format: ${REPORT_FORMAT})..."
      run_cmd notebooklm generate report \
        --notebook-id "$NOTEBOOK_ID" \
        --format "$REPORT_FORMAT" \
        --wait
      OUT="${OUTPUT_DIR}/report.md"
      run_cmd notebooklm download report \
        --notebook-id "$NOTEBOOK_ID" \
        "$OUT"
      [[ "$DRY_RUN" == "false" && -f "$OUT" ]] && GENERATED_FILES+=("$OUT") && ok "Downloaded: ${OUT}"
      [[ "$DRY_RUN" == "true" ]] && GENERATED_FILES+=("$OUT")
      ;;

    *)
      warn "Unknown type '${type}' — skipping. Valid: audio,video,slide-deck,infographic,quiz,flashcards,report"
      ;;
  esac
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo "" >&2
info "Generation complete. Files:"
for f in "${GENERATED_FILES[@]}"; do
  if [[ "$DRY_RUN" == "false" ]]; then
    size=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
    info "  ${f} (${size})"
  else
    info "  ${f} [dry-run]"
  fi
done

# ── Upload ────────────────────────────────────────────────────────────────────
if [[ "$SKIP_UPLOAD" == "true" ]]; then
  info "Skipping upload (--skip-upload set)."
  exit 0
fi

if [[ ${#GENERATED_FILES[@]} -eq 0 ]]; then
  warn "No files generated — nothing to upload."
  exit 0
fi

info "Uploading ${#GENERATED_FILES[@]} file(s) to release ${RELEASE_TAG}..."
run_cmd bash "${SCRIPT_DIR}/upload-notebooklm.sh" "$RELEASE_TAG" "${GENERATED_FILES[@]}"
ok "Done."
