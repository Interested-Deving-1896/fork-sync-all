#!/usr/bin/env bash
#
# hw-detect.sh — KPort hardware detection integration shim
#
# Thin wrapper around KPort's detection scripts. Consumer repos source or
# call this file to get CPU/GPU/NPU tier variables without depending on the
# full KPort package manager.
#
# Usage (source into current shell):
#   source scripts/hw-detect.sh
#   echo "CPU: $CPU_TIER  GPU: $GPU_TIER  NPU: $NPU_TIER"
#
# Usage (run and capture):
#   eval "$(bash scripts/hw-detect.sh --export)"
#
# Usage (JSON output for CI/scripts):
#   bash scripts/hw-detect.sh --json
#
# Variables set after sourcing:
#   CPU_ARCH      — x86-64 | i686 | aarch64 | riscv64 | unknown
#   CPU_TIER      — x86-64-v1..v4 | i686-baseline | i686-sse3
#                   aarch64-v8..v9.2 | riscv64-rv64gc | riscv64-rv64gcv
#   CPU_FLAGS     — space-separated CPU feature flags
#   CPU_MODEL     — human-readable CPU model string
#   CPU_CORES     — logical core count
#   GPU_TIER      — gpu-sw | gpu-gl2 | gpu-gl4 | gpu-vk12 | gpu-vk13
#                   gpu-mali-g52 | gpu-mali-g610 | gpu-immortalis-g715
#                   gpu-adreno-6xx | gpu-adreno-7xx | gpu-img-bxm
#   GPU_VENDOR    — gpu-intel | gpu-amd | gpu-nvidia | gpu-mali | gpu-adreno
#                   gpu-powervr | gpu-immortalis | gpu-apple | gpu-unknown
#   GPU_FLAGS     — space-separated GPU capability flags (vulkan, vaapi, opencl)
#   GPU_MODEL     — human-readable GPU model string
#   GPU_VRAM_MB   — VRAM in MiB (0 if unknown / unified memory)
#   NPU_TIER      — npu-none | npu-igpu | npu-dedicated | npu-ai | npu-datacenter
#   NPU_FLAGS     — space-separated NPU capability flags
#   NPU_MODEL     — NPU/accelerator model name
#   NPU_TOPS      — estimated TOPS (0 if unknown)
#
# Arch support (matching penguins-eggs release targets):
#   amd64 (x86-64), i386 (i686), arm64 (aarch64), riscv64
#
# This file is managed by fork-sync-all/propagate-hw-detect.
# Do not edit manually — changes will be overwritten on next sync.
# Source: https://github.com/Interested-Deving-1896/KPort

set -uo pipefail

_HW_DETECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_KPORT_DETECT="${_HW_DETECT_DIR}/kport/kport-detect.sh"

if [[ ! -f "$_KPORT_DETECT" ]]; then
  echo "[hw-detect] ERROR: kport-detect.sh not found at ${_KPORT_DETECT}" >&2
  echo "[hw-detect] Run: bash scripts/propagate-hw-detect.sh (from fork-sync-all)" >&2
  exit 1
fi

# Pass through all arguments to the orchestrator
exec bash "$_KPORT_DETECT" "$@"
