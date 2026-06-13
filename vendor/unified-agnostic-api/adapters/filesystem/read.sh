#!/usr/bin/env bash
# adapters/filesystem/read.sh — read file contents
# GET /api/filesystem/read?path=<file>&encoding=text|base64
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

auth_check

TARGET_PATH="$(query_param path "")"
ENCODING="$(query_param encoding "text")"

[[ -z "$TARGET_PATH" ]] && { respond_error 400 "missing path parameter"; exit 0; }

abs_path="$(realpath -m "$TARGET_PATH" 2>/dev/null || echo "$TARGET_PATH")"
ALLOWED_ROOTS="${UAA_FS_ROOTS:-/tmp:/var/uaa-data}"
allowed=false
IFS=':' read -ra roots <<< "$ALLOWED_ROOTS"
for root in "${roots[@]}"; do
  [[ "$abs_path" == "$root"* ]] && allowed=true && break
done
[[ "$allowed" != "true" ]] && { respond_error 403 "path outside allowed roots"; exit 0; }
[[ ! -f "$abs_path" ]]     && { respond_error 404 "file not found: $TARGET_PATH"; exit 0; }

case "$ENCODING" in
  base64)
    content="$(base64 < "$abs_path")"
    respond_json 200 "{\"path\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$abs_path"),\"encoding\":\"base64\",\"content\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$content")}"
    ;;
  text|*)
    content="$(cat "$abs_path")"
    respond_json 200 "{\"path\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$abs_path"),\"encoding\":\"text\",\"content\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$content")}"
    ;;
esac
