#!/usr/bin/env bash
# GET /api/fsa/bdfs/status
# Returns bdfs daemon status and available integration backends.
# Works on self-hosted runners/devcontainers with bdfs installed.
# Returns degraded status (not an error) when bdfs is not available.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

# Check bdfs availability
if ! command -v bdfs &>/dev/null; then
  echo '{"ok":true,"available":false,"reason":"bdfs not installed","backends":[]}'
  exit 0
fi

# Get bdfs status
status_raw=$(bdfs status --json 2>/dev/null || echo '{}')

# Detect available integration backends
backends=()
command -v ostree    &>/dev/null && backends+=("ostree")
command -v bootc     &>/dev/null && backends+=("bootc")
command -v incus     &>/dev/null && backends+=("incus")
command -v devcontainer &>/dev/null && backends+=("devcontainer")

backends_json=$(python3 -c "import json; print(json.dumps($(IFS=,; echo "[$(printf '"%s",' "${backends[@]}" | sed 's/,$//')]")))" 2>/dev/null || echo '[]')

python3 -c "
import json, sys

status = json.loads('''${status_raw}''') if '''${status_raw}''' != '{}' else {}
backends = json.loads('''${backends_json}''')

print(json.dumps({
    'ok': True,
    'available': True,
    'daemon_status': status,
    'backends': backends,
    'backend_count': len(backends),
}, indent=2))
" 2>/dev/null || echo '{"ok":true,"available":true,"backends":[]}'
