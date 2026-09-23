#!/usr/bin/env bash
# GET /api/fsa/support-bundles/:id/download
# Emits the verified ZIP payload. The route is auth-gated in fsa-routes.yml.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
BUNDLE_ID="${ROUTE_id:-${PATH_id:-}}"
BUNDLE="${ROOT}/artifacts/support-bundles/${BUNDLE_ID}.zip"

[[ "$BUNDLE_ID" =~ ^fsa-support-[A-Za-z0-9TZ-]+$ ]] || exit 1
python3 "${ROOT}/scripts/support-bundle.py" inspect "$BUNDLE" >/dev/null
cat "$BUNDLE"
