#!/usr/bin/env bash
# POST /api/fsa/support-bundles
# Body: {"profile":"minimal|standard|full","include_remote":false}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
PROFILE="${BODY_profile:-standard}"
INCLUDE_REMOTE="${BODY_include_remote:-false}"
OUTPUT="${ROOT}/artifacts/support-bundles"

case "$PROFILE" in minimal|standard|full) ;; *)
  printf '{"ok":false,"error":"invalid profile"}\n'
  exit 1
esac
case "$INCLUDE_REMOTE" in true|false) ;; *)
  printf '{"ok":false,"error":"include_remote must be true or false"}\n'
  exit 1
esac

args=(create --profile "$PROFILE" --output "$OUTPUT")
[[ "$INCLUDE_REMOTE" == "true" ]] && args+=(--include-remote)
exec python3 "${ROOT}/scripts/support-bundle.py" "${args[@]}"
