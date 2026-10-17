#!/usr/bin/env bash
# POST /api/fsa/support-bundles/:id/send
# Body: {"transport":"local|http","destination":"...","method":"PUT|POST"}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
BUNDLE_ID="${ROUTE_id:-${PATH_id:-}}"
TRANSPORT="${BODY_transport:-}"
DESTINATION="${BODY_destination:-}"
METHOD="${BODY_method:-PUT}"
BUNDLE="${ROOT}/artifacts/support-bundles/${BUNDLE_ID}.zip"

[[ "$BUNDLE_ID" =~ ^fsa-support-[A-Za-z0-9TZ-]+$ ]] || {
  printf '{"ok":false,"error":"invalid bundle id"}\n'
  exit 1
}
case "$TRANSPORT" in local|http) ;; *)
  printf '{"ok":false,"error":"invalid transport"}\n'
  exit 1
esac
case "$METHOD" in PUT|POST) ;; *)
  printf '{"ok":false,"error":"method must be PUT or POST"}\n'
  exit 1
esac

# API-triggered local delivery is confined to the workspace. CLI users may
# choose other local destinations directly through support-bundle.py.
if [[ "$TRANSPORT" == "local" ]]; then
  [[ -n "$DESTINATION" ]] || {
    printf '{"ok":false,"error":"destination is required for local delivery"}\n'
    exit 1
  }
  destination_is_dir=false
  [[ "$DESTINATION" == */ ]] && destination_is_dir=true
  destination_real="$(realpath -m "$DESTINATION")"
  workspace_real="$(realpath -m "$ROOT")"
  case "$destination_real" in "$workspace_real"/*) ;; *)
    printf '{"ok":false,"error":"local destination must be inside the workspace"}\n'
    exit 1
  esac
  if [[ "$destination_is_dir" == "true" ]]; then
    mkdir -p "$destination_real"
    DESTINATION="${destination_real}/"
  else
    DESTINATION="$destination_real"
  fi
else
  # Prevent authenticated API callers from turning the FSA server into an
  # arbitrary HTTPS upload proxy. Operators configure one support endpoint in
  # server state; the request body may omit it or repeat it exactly.
  configured_destination="${FSA_SUPPORT_UPLOAD_URL:-}"
  [[ -n "$configured_destination" ]] || {
    printf '{"ok":false,"error":"HTTP delivery is not configured on this FSA server"}\n'
    exit 1
  }
  if [[ -n "$DESTINATION" && "$DESTINATION" != "$configured_destination" ]]; then
    printf '{"ok":false,"error":"destination does not match the configured support endpoint"}\n'
    exit 1
  fi
  DESTINATION="$configured_destination"
fi

exec python3 "${ROOT}/scripts/support-bundle.py" send "$BUNDLE" \
  --transport "$TRANSPORT" --destination "$DESTINATION" --method "$METHOD"
