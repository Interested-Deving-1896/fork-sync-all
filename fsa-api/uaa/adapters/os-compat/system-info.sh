#!/usr/bin/env bash
# adapters/os-compat/system-info.sh — cross-platform system information
# GET /api/os/info
#
# Inspired by fmartini23/cross-platform-system-interaction system namespace.
# Works on Linux, macOS, and WSL.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

OS_TYPE="$(uname -s)"
OS_ARCH="$(uname -m)"
OS_VERSION="$(uname -r)"
HOSTNAME_VAL="$(hostname -f 2>/dev/null || hostname)"
CPU_COUNT="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)"
UPTIME_SECS="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || sysctl -n kern.boottime 2>/dev/null | awk '{print $4}' | tr -d ',' || echo 0)"

# Memory (Linux: /proc/meminfo; macOS: vm_stat)
if [[ -f /proc/meminfo ]]; then
  MEM_TOTAL="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  MEM_FREE="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
  MEM_UNIT="kB"
elif command -v vm_stat &>/dev/null; then
  PAGE_SIZE="$(pagesize 2>/dev/null || echo 4096)"
  MEM_FREE="$(vm_stat | awk '/Pages free/ {gsub(/\./,"",$3); print $3 * '"$PAGE_SIZE"' / 1024}')"
  MEM_TOTAL="$(sysctl -n hw.memsize 2>/dev/null | awk '{print $1/1024}')"
  MEM_UNIT="kB"
else
  MEM_TOTAL=0; MEM_FREE=0; MEM_UNIT="unknown"
fi

# Distro (Linux only)
DISTRO=""
if [[ -f /etc/os-release ]]; then
  DISTRO="$(. /etc/os-release && echo "${PRETTY_NAME:-$NAME}")"
fi

python3 - "$OS_TYPE" "$OS_ARCH" "$OS_VERSION" "$HOSTNAME_VAL" \
          "$CPU_COUNT" "$UPTIME_SECS" "$MEM_TOTAL" "$MEM_FREE" \
          "$MEM_UNIT" "$DISTRO" << 'PYEOF'
import json, sys
os_type, arch, version, hostname, cpus, uptime, mem_total, mem_free, mem_unit, distro = sys.argv[1:]
print(json.dumps({
    "os":       os_type,
    "arch":     arch,
    "version":  version,
    "hostname": hostname,
    "cpus":     int(cpus),
    "uptime_seconds": int(uptime) if uptime.isdigit() else 0,
    "memory": {
        "total": int(float(mem_total)) if mem_total else 0,
        "free":  int(float(mem_free))  if mem_free  else 0,
        "unit":  mem_unit
    },
    "distro": distro
}, indent=2))
PYEOF
