#!/usr/bin/env bash
# adapters/filesystem/stat.sh — stat a file or directory
# GET /api/filesystem/stat?path=<path>
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

TARGET_PATH="$(query_param path "")"
[[ -z "$TARGET_PATH" ]] && { respond_error 400 "missing path parameter"; exit 0; }

abs_path="$(realpath -m "$TARGET_PATH" 2>/dev/null || echo "$TARGET_PATH")"
[[ ! -e "$abs_path" ]] && { respond_error 404 "path not found: $TARGET_PATH"; exit 0; }

python3 - "$abs_path" << 'PYEOF'
import os, sys, json, stat as statmod

path = sys.argv[1]
st = os.stat(path)
mode = statmod.S_IMODE(st.st_mode)
ftype = "directory" if statmod.S_ISDIR(st.st_mode) else \
        "symlink"   if statmod.S_ISLNK(st.st_mode) else "file"

print(json.dumps({
    "path": path,
    "type": ftype,
    "size": st.st_size,
    "permissions": oct(mode),
    "uid": st.st_uid,
    "gid": st.st_gid,
    "atime": int(st.st_atime),
    "mtime": int(st.st_mtime),
    "ctime": int(st.st_ctime),
    "inode": st.st_ino,
    "nlinks": st.st_nlink
}, indent=2))
PYEOF
