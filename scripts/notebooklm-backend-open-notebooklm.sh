#!/usr/bin/env bash
# scripts/notebooklm-backend-open-notebooklm.sh — gabrielchua/open-notebooklm backend
#
# Generates a podcast MP3 from a PDF source using open-notebooklm.
# https://github.com/gabrielchua/open-notebooklm
#
# Runs the Gradio app locally (python app.py) and submits via the Gradio API,
# or calls the Hugging Face Spaces API if OPEN_NOTEBOOKLM_SPACE is set.
#
# Environment:
#   FIREWORKS_API_KEY          — Fireworks AI API key for Llama 3.3 70B
#   SOURCE_PDF                 — path to source PDF (relative to repo root)
#   CONTENT_TYPES              — comma-separated: audio-overview
#   OUTPUT_DIR                 — local directory for downloaded artifacts
#   DRY_RUN                    — true|false
#   OPEN_NOTEBOOKLM_SPACE      — optional HF Space ID (default: gabrielchua/open-notebooklm)
set -uo pipefail

info() { echo "[open-notebooklm] $*" >&2; }
warn() { echo "[open-notebooklm] warn: $*" >&2; }
die()  { echo "[open-notebooklm] error: $*" >&2; exit 1; }
dry()  { echo "[open-notebooklm] [dry-run] $*" >&2; }

: "${FIREWORKS_API_KEY:?Set FIREWORKS_API_KEY}"
: "${CONTENT_TYPES:?Set CONTENT_TYPES}"
SOURCE_PDF="${SOURCE_PDF:-}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/notebooklm-output}"
DRY_RUN="${DRY_RUN:-false}"
HF_SPACE="${OPEN_NOTEBOOKLM_SPACE:-gabrielchua/open-notebooklm}"

mkdir -p "$OUTPUT_DIR"

# Validate source PDF
if [[ -z "$SOURCE_PDF" ]]; then
  die "SOURCE_PDF is required for open-notebooklm backend. Set source_pdf in workflow inputs."
fi
if [[ ! -f "$SOURCE_PDF" ]]; then
  die "Source PDF not found: ${SOURCE_PDF}"
fi

IFS=',' read -ra TYPES <<< "$CONTENT_TYPES"
for type in "${TYPES[@]}"; do
  type="${type// /}"
  info "Generating: ${type}"

  case "$type" in
    audio-overview)
      if [[ "$DRY_RUN" == "true" ]]; then
        dry "pip install gradio-client"
        dry "gradio_client.Client('${HF_SPACE}').predict(pdf='${SOURCE_PDF}', ...)"
        dry "Download -> ${OUTPUT_DIR}/audio-overview.mp3"
      else
        # Install gradio-client if not present
        pip install --quiet gradio-client 2>/dev/null || true

        info "Submitting PDF to ${HF_SPACE}..."
        python3 - << PYEOF
import sys, os
try:
    from gradio_client import Client, handle_file
except ImportError:
    print("[open-notebooklm] error: gradio-client not installed", file=sys.stderr)
    sys.exit(1)

client = Client("${HF_SPACE}")
result = client.predict(
    pdf_file=handle_file("${SOURCE_PDF}"),
    openai_api_key="${FIREWORKS_API_KEY}",
    text_model="accounts/fireworks/models/llama-v3p3-70b-instruct",
    audio_model="suno/bark-small",
    api_name="/generate_podcast"
)
# result is typically a tuple (audio_path, transcript)
audio_path = result[0] if isinstance(result, (list, tuple)) else result
if audio_path and os.path.exists(str(audio_path)):
    import shutil
    shutil.copy(str(audio_path), "${OUTPUT_DIR}/audio-overview.mp3")
    print(f"[open-notebooklm] Downloaded: ${OUTPUT_DIR}/audio-overview.mp3", file=sys.stderr)
else:
    print(f"[open-notebooklm] warn: unexpected result: {result}", file=sys.stderr)
    sys.exit(1)
PYEOF
      fi
      ;;

    *)
      warn "Content type '${type}' not supported by open-notebooklm backend. Supported: audio-overview"
      ;;
  esac
done

info "Done."
