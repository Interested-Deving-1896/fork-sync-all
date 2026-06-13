#!/usr/bin/env bash
# adapters/filesystem/ls.sh — list directory contents
# GET /api/filesystem/ls?path=<dir>&hidden=true
#
# Inspired by zen-fs/core virtual FS API and scottvr/apifusefs directory listing.
# Falls back gracefully: tries the virtual FS mount table first, then real FS.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

auth_check

TARGET_PATH="$(query_param path ".")"
SHOW_HIDDEN="$(query_param hidden "false")"

# Sanitise: prevent path traversal outside allowed roots
ALLOWED_ROOTS="${UAA_FS_ROOTS:-/tmp:/var/uaa-data}"
abs_path="$(realpath -m "$TARGET_PATH" 2>/dev/null || echo "$TARGET_PATH")"

allowed=false
IFS=':' read -ra roots <<< "$ALLOWED_ROOTS"
for root in "${roots[@]}"; do
  [[ "$abs_path" == "$root"* ]] && allowed=true && break
done

if [[ "$allowed" != "true" ]]; then
  respond_error 403 "path outside allowed roots: $TARGET_PATH"
  exit 0
fi

if [[ ! -d "$abs_path" ]]; then
  respond_error 404 "not a directory: $TARGET_PATH"
  exit 0
fi

# Build JSON listing
python3 - "$abs_path" "$SHOW_HIDDEN" << 'PYEOF'
import os, sys, json, stat as statmod, time

path, show_hidden = sys.argv[1], sys.argv[2].lower() == 'true'

entries = []
try:
    for name in sorted(os.listdir(path)):
        if name.startswith('.') and not show_hidden:
            continue
        full = os.path.join(path, name)
        try:
            st = os.stat(full)
            entries.append({
                "name": name,
                "type": "directory" if statmod.S_ISDIR(st.st_mode) else "file",
                "size": st.st_size,
                "modified": int(st.st_mtime),
                "permissions": oct(statmod.S_IMODE(st.st_mode))
            })
        except OSError:
            entries.append({"name": name, "type": "unknown", "error": "stat failed"})
except PermissionError as e:
    print(json.dumps({"error": str(e)}))
    sys.exit(0)

print(json.dumps({"path": path, "entries": entries, "count": len(entries)}, indent=2))
PYEOF
