#!/usr/bin/env bash
# GET /api/fsa/support-bundles/:id

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
BUNDLE_ID="${ROUTE_id:-${PATH_id:-}}"

[[ "$BUNDLE_ID" =~ ^fsa-support-[A-Za-z0-9TZ-]+$ ]] || {
  printf '{"ok":false,"error":"invalid bundle id"}\n'
  exit 1
}

exec python3 "${ROOT}/scripts/support-bundle.py" inspect \
  "${ROOT}/artifacts/support-bundles/${BUNDLE_ID}.zip"
