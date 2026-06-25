#!/usr/bin/env bash
# adapters/filesystem/write.sh — write content to a file
# POST /api/filesystem/write
# Body: {"path":"...","content":"...","encoding":"text|base64","mkdir":true}
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

auth_check

body="$(request_body)"
[[ -z "$body" ]] && { respond_error 400 "empty request body"; exit 0; }

# Parse body via temp file to avoid shell interpolation issues
tmp="$(mktemp)"
echo "$body" > "$tmp"

python3 - "$tmp" "${UAA_FS_ROOTS:-/tmp:/var/uaa-data}" << 'PYEOF'
import json, sys, os, base64, stat as statmod

tmp_file, allowed_roots_str = sys.argv[1], sys.argv[2]
with open(tmp_file) as f:
    data = json.load(f)
os.unlink(tmp_file)

path     = data.get('path', '')
content  = data.get('content', '')
encoding = data.get('encoding', 'text')
mkdir    = data.get('mkdir', False)

if not path:
    print(json.dumps({"error": "missing path"}))
    sys.exit(0)

abs_path = os.path.realpath(path)
allowed = any(abs_path.startswith(r) for r in allowed_roots_str.split(':'))
if not allowed:
    print(json.dumps({"error": f"path outside allowed roots: {path}"}))
    sys.exit(0)

if mkdir:
    os.makedirs(os.path.dirname(abs_path), exist_ok=True)

if encoding == 'base64':
    raw = base64.b64decode(content)
    with open(abs_path, 'wb') as f:
        f.write(raw)
    size = len(raw)
else:
    with open(abs_path, 'w') as f:
        f.write(content)
    size = len(content.encode())

print(json.dumps({"path": abs_path, "size": size, "status": "written"}))
PYEOF
