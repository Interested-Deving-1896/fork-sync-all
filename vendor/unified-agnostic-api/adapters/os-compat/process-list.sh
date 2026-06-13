#!/usr/bin/env bash
# adapters/os-compat/process-list.sh — cross-platform process listing
# GET /api/os/process/list?filter=<name>&limit=50
#
# Inspired by fmartini23/cross-platform-system-interaction process namespace.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

FILTER="$(query_param filter "")"
LIMIT="$(query_param limit "50")"

OS_TYPE="$(uname -s)"

case "$OS_TYPE" in
  Linux)
    PS_OUT="$(ps -eo pid,ppid,user,pcpu,pmem,comm --no-headers 2>/dev/null)"
    ;;
  Darwin)
    PS_OUT="$(ps -eo pid,ppid,user,pcpu,pmem,comm 2>/dev/null | tail -n +2)"
    ;;
  *)
    PS_OUT="$(ps -e -o pid,ppid,user,pcpu,pmem,comm 2>/dev/null | tail -n +2)"
    ;;
esac

python3 - "$PS_OUT" "$FILTER" "$LIMIT" << 'PYEOF'
import sys, json

raw, filt, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])
procs = []
for line in raw.strip().splitlines():
    parts = line.split(None, 5)
    if len(parts) < 6:
        continue
    pid, ppid, user, cpu, mem, comm = parts
    if filt and filt.lower() not in comm.lower():
        continue
    procs.append({
        "pid":  int(pid),
        "ppid": int(ppid),
        "user": user,
        "cpu":  float(cpu),
        "mem":  float(mem),
        "name": comm
    })
    if len(procs) >= limit:
        break

print(json.dumps({"count": len(procs), "processes": procs}, indent=2))
PYEOF
