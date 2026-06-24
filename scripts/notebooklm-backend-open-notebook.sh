#!/usr/bin/env bash
# scripts/notebooklm-backend-open-notebook.sh — open-notebook backend
#
# Generates content via the lfnovo/open-notebook REST API.
# https://github.com/lfnovo/open-notebook
#
# Environment (set by generate-notebooklm.sh / workflow):
#   OPEN_NOTEBOOK_URL      — base URL of the running instance (e.g. http://localhost:8502)
#   OPEN_NOTEBOOK_API_KEY  — API key configured in the instance
#   CONTENT_TYPES          — comma-separated: audio-overview,reports
#   OUTPUT_DIR             — local directory for downloaded artifacts
#   DRY_RUN                — true|false
set -uo pipefail

info() { echo "[open-notebook] $*" >&2; }
warn() { echo "[open-notebook] warn: $*" >&2; }
die()  { echo "[open-notebook] error: $*" >&2; exit 1; }
dry()  { echo "[open-notebook] [dry-run] $*" >&2; }

: "${OPEN_NOTEBOOK_URL:?Set OPEN_NOTEBOOK_URL to the base URL of your open-notebook instance}"
: "${OPEN_NOTEBOOK_API_KEY:?Set OPEN_NOTEBOOK_API_KEY}"
: "${CONTENT_TYPES:?Set CONTENT_TYPES}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/notebooklm-output}"
DRY_RUN="${DRY_RUN:-false}"

mkdir -p "$OUTPUT_DIR"

api_post() {
  local endpoint="$1" payload="$2"
  curl -sf -X POST \
    -H "Authorization: Bearer ${OPEN_NOTEBOOK_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${OPEN_NOTEBOOK_URL}${endpoint}" 2>/dev/null
}

IFS=',' read -ra TYPES <<< "$CONTENT_TYPES"
for type in "${TYPES[@]}"; do
  type="${type// /}"
  info "Generating: ${type}"

  case "$type" in
    audio-overview)
      if [[ "$DRY_RUN" == "true" ]]; then
        dry "POST ${OPEN_NOTEBOOK_URL}/api/podcast/generate"
        dry "Download -> ${OUTPUT_DIR}/audio-overview.mp3"
      else
        # Trigger podcast generation
        job=$(api_post "/api/podcast/generate" '{"format":"two_speakers","language":"en"}')
        job_id=$(echo "$job" | python3 -c "import json,sys; print(json.load(sys.stdin).get('job_id',''))" 2>/dev/null || echo "")
        if [[ -z "$job_id" ]]; then
          warn "Failed to start podcast generation — check OPEN_NOTEBOOK_URL and OPEN_NOTEBOOK_API_KEY"
          continue
        fi
        info "Job ID: ${job_id} — polling for completion..."
        # Poll until done (max 30 min)
        for i in $(seq 1 180); do
          status=$(curl -sf \
            -H "Authorization: Bearer ${OPEN_NOTEBOOK_API_KEY}" \
            "${OPEN_NOTEBOOK_URL}/api/jobs/${job_id}" 2>/dev/null \
            | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
          [[ "$status" == "completed" ]] && break
          [[ "$status" == "failed" ]] && die "Job ${job_id} failed"
          sleep 10
        done
        # Download
        curl -sf \
          -H "Authorization: Bearer ${OPEN_NOTEBOOK_API_KEY}" \
          "${OPEN_NOTEBOOK_URL}/api/jobs/${job_id}/download" \
          -o "${OUTPUT_DIR}/audio-overview.mp3" \
          && info "Downloaded: ${OUTPUT_DIR}/audio-overview.mp3" \
          || warn "Download failed for job ${job_id}"
      fi
      ;;

    reports)
      if [[ "$DRY_RUN" == "true" ]]; then
        dry "POST ${OPEN_NOTEBOOK_URL}/api/transform"
        dry "Download -> ${OUTPUT_DIR}/report.md"
      else
        job=$(api_post "/api/transform" '{"transformation":"summary","output_format":"markdown"}')
        job_id=$(echo "$job" | python3 -c "import json,sys; print(json.load(sys.stdin).get('job_id',''))" 2>/dev/null || echo "")
        if [[ -z "$job_id" ]]; then
          warn "Failed to start transformation"
          continue
        fi
        for i in $(seq 1 60); do
          status=$(curl -sf \
            -H "Authorization: Bearer ${OPEN_NOTEBOOK_API_KEY}" \
            "${OPEN_NOTEBOOK_URL}/api/jobs/${job_id}" 2>/dev/null \
            | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
          [[ "$status" == "completed" ]] && break
          [[ "$status" == "failed" ]] && die "Job ${job_id} failed"
          sleep 5
        done
        curl -sf \
          -H "Authorization: Bearer ${OPEN_NOTEBOOK_API_KEY}" \
          "${OPEN_NOTEBOOK_URL}/api/jobs/${job_id}/download" \
          -o "${OUTPUT_DIR}/report.md" \
          && info "Downloaded: ${OUTPUT_DIR}/report.md" \
          || warn "Download failed for job ${job_id}"
      fi
      ;;

    *)
      warn "Content type '${type}' not supported by open-notebook backend. Supported: audio-overview, reports"
      ;;
  esac
done

info "Done."
