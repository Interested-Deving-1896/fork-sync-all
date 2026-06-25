#!/usr/bin/env bash
# adapters/filesystem/mount.sh — mount a virtual filesystem backend
# POST /api/filesystem/mount
# Body: {"backend":"memory|archive|ipfs","source":"...","mountpoint":"..."}
#
# Inspired by zen-fs/core backend plugin architecture and SupraSummus/ipfs-api-mount.
# In shell context: manages a mount registry in /var/uaa-data/mounts.json.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

auth_check

body="$(request_body)"
[[ -z "$body" ]] && { respond_error 400 "empty request body"; exit 0; }

MOUNT_REGISTRY="${UAA_MOUNT_REGISTRY:-/var/uaa-data/mounts.json}"
mkdir -p "$(dirname "$MOUNT_REGISTRY")"
[[ -f "$MOUNT_REGISTRY" ]] || echo '{"mounts":[]}' > "$MOUNT_REGISTRY"

tmp="$(mktemp)"
echo "$body" > "$tmp"

python3 - "$tmp" "$MOUNT_REGISTRY" << 'PYEOF'
import json, sys, os, time

tmp_file, registry_file = sys.argv[1], sys.argv[2]
with open(tmp_file) as f:
    req = json.load(f)
os.unlink(tmp_file)

backend    = req.get('backend', 'memory')
source     = req.get('source', '')
mountpoint = req.get('mountpoint', '')

if not mountpoint:
    print(json.dumps({"error": "missing mountpoint"}))
    sys.exit(0)

valid_backends = {'memory', 'archive', 'ipfs', 'indexeddb', 'http'}
if backend not in valid_backends:
    print(json.dumps({"error": f"unknown backend: {backend}. valid: {sorted(valid_backends)}"}))
    sys.exit(0)

with open(registry_file) as f:
    registry = json.load(f)

# Check for existing mount at same mountpoint
existing = [m for m in registry.get('mounts', []) if m['mountpoint'] == mountpoint]
if existing:
    print(json.dumps({"error": f"mountpoint already in use: {mountpoint}"}))
    sys.exit(0)

entry = {
    "id": f"{backend}-{int(time.time())}",
    "backend": backend,
    "source": source,
    "mountpoint": mountpoint,
    "mounted_at": int(time.time()),
    "status": "mounted"
}
registry.setdefault('mounts', []).append(entry)

with open(registry_file, 'w') as f:
    json.dump(registry, f, indent=2)

print(json.dumps({"status": "mounted", "mount": entry}, indent=2))
PYEOF
