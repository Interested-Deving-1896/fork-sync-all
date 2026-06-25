#!/usr/bin/env bash
#
# generate-notebooklm.sh
#
# Backend-agnostic NotebookLM content generator. Dispatches to the appropriate
# generation logic based on BACKEND env var. Reads config/notebooklm-backends.yml
# for backend metadata.
#
# Supported backends (set via BACKEND env var):
#   google-notebooklm  — Google NotebookLM via notebooklm-py (default)
#   open-notebook      — lfnovo/open-notebook self-hosted instance
#   openbooklm         — open-biz/OpenBookLM self-hosted instance
#   open-notebooklm    — gabrielchua/open-notebooklm (PDF→podcast)
#
# Usage (env-driven, called from workflow):
#   BACKEND=google-notebooklm CONTENT_TYPES=audio-overview bash scripts/generate-notebooklm.sh
#
# Legacy CLI flags (google-notebooklm only, for backwards compatibility):
#   --notebook-id ID      NotebookLM notebook ID
#   --types TYPES         Comma-separated content types
#   --release-tag TAG     GitHub Release tag (notebooklm-YYYY-MM-DD)
#   --output-dir DIR      Local output directory (default: /tmp/notebooklm-output)
#   --dry-run             Print commands without executing
#   --skip-upload         Skip GitHub Release upload
#   --audio-format FMT    deep-dive|brief|critique|debate
#   --video-format FMT    explainer|brief|cinematic
#   --report-format FMT   briefing-doc|study-guide|blog-post
#
# Environment:
#   BACKEND                    — backend ID (default: google-notebooklm)
#   CONTENT_TYPES              — comma-separated content types (default: audio-overview)
#   DOCS_DIR                   — docs output directory (from notebooklm-resolve-backend.sh)
#   DRY_RUN                    — true|false
#   SKIP_UPLOAD                — true|false
#   GH_TOKEN                   — PAT with contents:write (for upload)
#   REPO                       — target repo for upload (default: from github.repository)
#   NOTEBOOKLM_AUTH_JSON       — [google-notebooklm] browser session state JSON
#   NOTEBOOK_ID                — [google-notebooklm] notebook ID
#   AUDIO_FORMAT               — [google-notebooklm] audio format
#   VIDEO_FORMAT               — [google-notebooklm] video format
#   REPORT_FORMAT              — [google-notebooklm] report format
#   RELEASE_TAG                — [google-notebooklm] GitHub Release tag
#   FIREWORKS_API_KEY          — [open-notebooklm] Fireworks AI API key
#   SOURCE_PDF                 — [open-notebooklm] path to source PDF
#   OPEN_NOTEBOOK_URL          — [open-notebook] instance base URL
#   OPEN_NOTEBOOK_API_KEY      — [open-notebook] API key
#   OPENBOOKLM_URL             — [openbooklm] instance base URL
#   CEREBRAS_API_KEY           — [openbooklm] Cerebras API key

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
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Backend dispatch ──────────────────────────────────────────────────────────
# When called from the workflow, BACKEND and CONTENT_TYPES are set via env.
# Legacy CLI invocations (no BACKEND set) default to google-notebooklm.
BACKEND="${BACKEND:-google-notebooklm}"
CONTENT_TYPES="${CONTENT_TYPES:-}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_UPLOAD="${SKIP_UPLOAD:-false}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/notebooklm-output}"

# If CONTENT_TYPES is set (workflow mode), override TYPES and skip CLI parsing
if [[ -n "$CONTENT_TYPES" && "$BACKEND" != "google-notebooklm" ]]; then
  info "Backend: ${BACKEND}"
  info "Content types: ${CONTENT_TYPES}"
  mkdir -p "$OUTPUT_DIR"

  case "$BACKEND" in
    open-notebook)
      bash "${SCRIPT_DIR}/notebooklm-backend-open-notebook.sh"
      exit $?
      ;;
    openbooklm)
      bash "${SCRIPT_DIR}/notebooklm-backend-openbooklm.sh"
      exit $?
      ;;
    open-notebooklm)
      bash "${SCRIPT_DIR}/notebooklm-backend-open-notebooklm.sh"
      exit $?
      ;;
    *)
      fail "Unknown backend: ${BACKEND}"
      exit 1
      ;;
  esac
fi

# google-notebooklm: fall through to existing CLI-flag logic below
[[ -n "$CONTENT_TYPES" ]] && TYPES="$CONTENT_TYPES"
[[ -n "${NOTEBOOK_ID:-}" ]] && NOTEBOOK_ID_ENV="$NOTEBOOK_ID"
[[ -n "${RELEASE_TAG:-}" ]] && RELEASE_TAG_ENV="$RELEASE_TAG"
[[ -n "${AUDIO_FORMAT:-}" ]] && AUDIO_FORMAT="$AUDIO_FORMAT"
[[ -n "${VIDEO_FORMAT:-}" ]] && VIDEO_FORMAT="$VIDEO_FORMAT"
[[ -n "${REPORT_FORMAT:-}" ]] && REPORT_FORMAT="$REPORT_FORMAT"
[[ "$DRY_RUN" == "true" ]] && DRY_RUN=true
[[ "$SKIP_UPLOAD" == "true" ]] && SKIP_UPLOAD=true

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
