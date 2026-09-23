#!/usr/bin/env bash
# Platform-neutral entry point for Fork-Sync-All support bundles.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/support-bundle.py" "$@"
