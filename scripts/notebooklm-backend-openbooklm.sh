#!/usr/bin/env bash
# scripts/notebooklm-backend-openbooklm.sh — OpenBookLM backend
#
# Generates content via the open-biz/OpenBookLM API.
# https://github.com/open-biz/OpenBookLM
#
# Environment:
#   OPENBOOKLM_URL     — base URL of the running instance
#   CEREBRAS_API_KEY   — Cerebras API key (passed to the instance)
#   CONTENT_TYPES      — comma-separated: audio-overview,reports
#   OUTPUT_DIR         — local directory for downloaded artifacts
#   DRY_RUN            — true|false
set -uo pipefail

info() { echo "[openbooklm] $*" >&2; }
warn() { echo "[openbooklm] warn: $*" >&2; }
die()  { echo "[openbooklm] error: $*" >&2; exit 1; }
dry()  { echo "[openbooklm] [dry-run] $*" >&2; }

: "${OPENBOOKLM_URL:?Set OPENBOOKLM_URL to the base URL of your OpenBookLM instance}"
: "${CEREBRAS_API_KEY:?Set CEREBRAS_API_KEY}"
: "${CONTENT_TYPES:?Set CONTENT_TYPES}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/notebooklm-output}"
DRY_RUN="${DRY_RUN:-false}"

mkdir -p "$OUTPUT_DIR"

IFS=',' read -ra TYPES <<< "$CONTENT_TYPES"
for type in "${TYPES[@]}"; do
  type="${type// /}"
  info "Generating: ${type}"

  case "$type" in
    audio-overview)
      if [[ "$DRY_RUN" == "true" ]]; then
        dry "POST ${OPENBOOKLM_URL}/api/generate-audio"
        dry "Download -> ${OUTPUT_DIR}/audio-overview.mp3"
      else
        # OpenBookLM: POST /api/generate-audio with source content
        job=$(curl -sf -X POST \
          -H "Content-Type: application/json" \
          -H "X-Cerebras-Key: ${CEREBRAS_API_KEY}" \
          -d '{"language":"en","num_speakers":2}' \
          "${OPENBOOKLM_URL}/api/generate-audio" 2>/dev/null || echo "{}")
        job_id=$(echo "$job" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
        if [[ -z "$job_id" ]]; then
          warn "Failed to start audio generation — check OPENBOOKLM_URL and CEREBRAS_API_KEY"
          continue
        fi
        info "Job ID: ${job_id} — polling..."
        for i in $(seq 1 180); do
          status=$(curl -sf \
            "${OPENBOOKLM_URL}/api/jobs/${job_id}" 2>/dev/null \
            | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
          [[ "$status" == "done" || "$status" == "completed" ]] && break
          [[ "$status" == "error" || "$status" == "failed" ]] && die "Job ${job_id} failed"
          sleep 10
        done
        curl -sf \
          "${OPENBOOKLM_URL}/api/jobs/${job_id}/audio" \
          -o "${OUTPUT_DIR}/audio-overview.mp3" \
          && info "Downloaded: ${OUTPUT_DIR}/audio-overview.mp3" \
          || warn "Download failed for job ${job_id}"
      fi
      ;;

    reports)
      if [[ "$DRY_RUN" == "true" ]]; then
        dry "POST ${OPENBOOKLM_URL}/api/export"
        dry "Download -> ${OUTPUT_DIR}/report.md"
      else
        result=$(curl -sf -X POST \
          -H "Content-Type: application/json" \
          -H "X-Cerebras-Key: ${CEREBRAS_API_KEY}" \
          -d '{"format":"markdown"}' \
          "${OPENBOOKLM_URL}/api/export" 2>/dev/null || echo "{}")
        content=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('content',''))" 2>/dev/null || echo "")
        if [[ -n "$content" ]]; then
          echo "$content" > "${OUTPUT_DIR}/report.md"
          info "Downloaded: ${OUTPUT_DIR}/report.md"
        else
          warn "No content returned from export endpoint"
        fi
      fi
      ;;

    *)
      warn "Content type '${type}' not supported by openbooklm backend. Supported: audio-overview, reports"
      ;;
  esac
done

info "Done."
