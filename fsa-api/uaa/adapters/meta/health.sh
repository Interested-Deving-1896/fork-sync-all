#!/usr/bin/env bash
# adapters/meta/health.sh — server health check endpoint
# GET /health
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

uptime_val="$(uptime -p 2>/dev/null || uptime)"
respond_json 200 "{\"status\":\"ok\",\"uptime\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$uptime_val")}"
