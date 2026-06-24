#!/usr/bin/env bash
#
# hw-build-env.sh — hardware-aware build environment setup
#
# Single entry point for consumer repos (btrfs-dwarfs-framework, oa-tools,
# penguins-eggs, etc.) to get a fully configured build environment that
# reflects the detected CPU/GPU/NPU hardware.
#
# Combines:
#   scripts/hw-detect.sh               — CPU/GPU/NPU tier detection
#   scripts/kport/kport-build-flags.sh — compiler/linker flag derivation
#   scripts/kport/kport-toolchain.sh   — cross-compile toolchain (optional)
#   scripts/kport/kport-neon-env.sh    — KDE Neon apt + version setup (optional)
#   scripts/kport/kport-neon-flags.sh  — Qt6/KF6 cmake args (optional)
#
# Usage (source into current shell — most common):
#   source scripts/hw-build-env.sh
#   cmake $KPORT_CMAKE_ARGS ..
#   make  $KPORT_MAKE_ARGS
#
# Usage (cross-compile for a specific arch):
#   source scripts/hw-build-env.sh --cross arm64
#   cmake -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN_FILE" $KPORT_CMAKE_ARGS ..
#
# Usage (KDE Neon Qt6/KF6 build against stable channel):
#   source scripts/hw-build-env.sh --neon stable
#   cmake $KPORT_NEON_CMAKE_ARGS ..
#
# Usage (CI — export to environment):
#   eval "$(bash scripts/hw-build-env.sh --export)"
#   eval "$(bash scripts/hw-build-env.sh --export --neon unstable)"
#
# Usage (print JSON for scripting):
#   bash scripts/hw-build-env.sh --json
#   bash scripts/hw-build-env.sh --json --neon stable
#
# Variables exported after sourcing:
#   All CPU_*, GPU_*, NPU_* variables from hw-detect.sh
#   All KPORT_* variables from kport-build-flags.sh
#   CC, CXX, AR, STRIP, RANLIB (cross only)
#   CMAKE_TOOLCHAIN_FILE (cross only)
#   CARGO_BUILD_TARGET (cross only)
#   All NEON_* variables from kport-neon-env.sh (--neon only)
#   All KPORT_NEON_* variables from kport-neon-flags.sh (--neon only)
#
# Arch support: amd64, i386, arm64, riscv64
# (matches penguins-eggs / oa-tools release targets)
#
# This file is managed by fork-sync-all/propagate-hw-detect.
# Do not edit manually — changes will be overwritten on next sync.
# Source: https://github.com/Interested-Deving-1896/KPort

set -uo pipefail

_HW_BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HW_DETECT="${_HW_BUILD_DIR}/hw-detect.sh"
_BUILD_FLAGS="${_HW_BUILD_DIR}/kport/kport-build-flags.sh"
_TOOLCHAIN="${_HW_BUILD_DIR}/kport/kport-toolchain.sh"
_NEON_ENV="${_HW_BUILD_DIR}/kport/kport-neon-env.sh"
_NEON_FLAGS="${_HW_BUILD_DIR}/kport/kport-neon-flags.sh"

# ── Validate dependencies ─────────────────────────────────────────────────────

for _f in "$_HW_DETECT" "$_BUILD_FLAGS"; do
  if [[ ! -f "$_f" ]]; then
    echo "[hw-build-env] ERROR: missing $_f" >&2
    echo "[hw-build-env] Run propagate-hw-detect workflow to sync KPort scripts." >&2
    return 1 2>/dev/null || exit 1
  fi
done

# ── Parse arguments ───────────────────────────────────────────────────────────

_OUTPUT_MODE="source"
_CROSS_TARGET=""
_NEON_CHANNEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --export) _OUTPUT_MODE="export";        shift   ;;
    --json)   _OUTPUT_MODE="json";          shift   ;;
    --cross)  _CROSS_TARGET="${2:-}";       shift 2 ;;
    --neon)   _NEON_CHANNEL="${2:-stable}"; shift 2 ;;
    *)        shift ;;
  esac
done

# ── Step 1: detect hardware ───────────────────────────────────────────────────

eval "$(bash "$_HW_DETECT" --export 2>/dev/null)"

# ── Step 2: derive build flags ────────────────────────────────────────────────

_bf_args=("--${_OUTPUT_MODE}")
[[ -n "$_CROSS_TARGET" ]] && _bf_args+=("--cross" "$_CROSS_TARGET")

eval "$(bash "$_BUILD_FLAGS" "${_bf_args[@]}" 2>/dev/null)"

# ── Step 3: cross toolchain (if requested) ────────────────────────────────────

if [[ -n "$_CROSS_TARGET" && -f "$_TOOLCHAIN" ]]; then
  eval "$(bash "$_TOOLCHAIN" env "$_CROSS_TARGET" 2>/dev/null)"
fi

# ── Step 4: KDE Neon environment (if requested) ───────────────────────────────

if [[ -n "$_NEON_CHANNEL" ]]; then
  if [[ ! -f "$_NEON_ENV" || ! -f "$_NEON_FLAGS" ]]; then
    echo "[hw-build-env] WARN: KDE Neon scripts not found -- skipping Neon setup." >&2
    echo "[hw-build-env] Run propagate-hw-detect to sync kport-neon-env.sh and kport-neon-flags.sh." >&2
  else
    eval "$(bash "$_NEON_ENV"   --channel "$_NEON_CHANNEL" --export 2>/dev/null)"
    eval "$(bash "$_NEON_FLAGS" --channel "$_NEON_CHANNEL" --export 2>/dev/null)"
  fi
fi

# ── Step 5: output ────────────────────────────────────────────────────────────

case "$_OUTPUT_MODE" in
  source|export)
    # Already eval'd above -- print a summary to stderr for visibility
    cat >&2 <<SUMMARY
[hw-build-env] CPU: ${CPU_TIER:-?}  GPU: ${GPU_TIER:-?}  NPU: ${NPU_TIER:-?}
[hw-build-env] Arch: ${KPORT_ARCH:-?}  Cross: ${KPORT_CROSS:-false}  GPU backend: ${KPORT_GPU_BACKEND:-?}  NPU backend: ${KPORT_NPU_BACKEND:-?}
[hw-build-env] CFLAGS: ${KPORT_CFLAGS:-?}
SUMMARY
    if [[ -n "$_NEON_CHANNEL" ]]; then
      cat >&2 <<NEON_SUMMARY
[hw-build-env] Neon channel: ${NEON_CHANNEL:-?}  Qt: ${NEON_QT_VERSION:-?}  KF: ${NEON_KF_VERSION:-?}
[hw-build-env] Neon cmake args: ${KPORT_NEON_CMAKE_ARGS:-?}
NEON_SUMMARY
    fi
    ;;
  json)
    # Merge hw flags JSON with neon flags JSON if applicable
    if [[ -n "$_NEON_CHANNEL" && -f "$_NEON_FLAGS" ]]; then
      python3 -c "
import json, subprocess
hw   = json.loads(subprocess.check_output(['bash', '${_BUILD_FLAGS}', '--json'], stderr=subprocess.DEVNULL))
neon = json.loads(subprocess.check_output(['bash', '${_NEON_FLAGS}', '--channel', '${_NEON_CHANNEL}', '--json'], stderr=subprocess.DEVNULL))
print(json.dumps({**hw, **neon}, indent=2))
"
    else
      bash "$_BUILD_FLAGS" --json
    fi
    ;;
esac
