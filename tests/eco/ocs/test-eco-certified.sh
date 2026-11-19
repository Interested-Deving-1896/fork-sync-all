#!/usr/bin/env bash
# tests/eco/ocs/test-eco-certified.sh
#
# Protocol conformance tests for the OCS eco-certified adapter.
# Validates that GET /api/ocs/eco/certified returns a response compatible
# with the eco-label extension used by KDE Eco and the Green Web Foundation.
#
# Usage:
#   bash tests/eco/ocs/test-eco-certified.sh

set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../vendor/unified-agnostic-api/adapters/ocs" && pwd)"

pass() { echo "[PASS] $*" >&2; }
fail() { echo "[FAIL] $*" >&2; exit 1; }

# ── Test 1: adapter script exists ────────────────────────────────────────────
[[ -f "${ADAPTER_DIR}/eco-certified.sh" ]] || fail "eco-certified.sh not found"
pass "eco-certified.sh exists"

# ── Test 2: manifest declares the endpoint ───────────────────────────────────
grep -q "GET /api/ocs/eco/certified" "${ADAPTER_DIR}/manifest.yml" \
    || fail "manifest.yml does not declare GET /api/ocs/eco/certified"
pass "manifest.yml declares GET /api/ocs/eco/certified"

# ── Test 3: eco-certified.sh references GWF check ────────────────────────────
grep -qi "green.web\|thegreenwebfoundation\|gwf" "${ADAPTER_DIR}/eco-certified.sh" \
    || fail "eco-certified.sh does not reference Green Web Foundation check"
pass "eco-certified.sh references Green Web Foundation"

# ── Test 4: eco-certified.sh references KDE Eco ──────────────────────────────
grep -qi "kde.eco\|keco\|blue.angel\|blauer.engel" "${ADAPTER_DIR}/eco-certified.sh" \
    || fail "eco-certified.sh does not reference KDE Eco / Blue Angel"
pass "eco-certified.sh references KDE Eco / Blue Angel"

echo "[eco/ocs] All eco-certified conformance tests passed" >&2
