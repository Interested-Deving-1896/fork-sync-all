#!/usr/bin/env bash
#
# kport-build-flags.sh — emit compiler/linker flags derived from hardware tiers
#
# Reads CPU_TIER, GPU_TIER, NPU_TIER (from hardware.conf or environment) and
# outputs the appropriate CFLAGS, CXXFLAGS, RUSTFLAGS, LDFLAGS, and
# CMAKE_ARGS for the detected hardware.
#
# Usage:
#   source <(bash scripts/kport/kport-build-flags.sh)
#   bash scripts/kport/kport-build-flags.sh --export    # print export statements
#   bash scripts/kport/kport-build-flags.sh --cmake     # print -DCMAKE_* args
#   bash scripts/kport/kport-build-flags.sh --json      # print JSON
#   bash scripts/kport/kport-build-flags.sh --make      # print Make variable assignments
#   bash scripts/kport/kport-build-flags.sh --cross <arch>  # cross-compile flags for arch
#
# Variables set:
#   KPORT_CFLAGS        — C compiler flags
#   KPORT_CXXFLAGS      — C++ compiler flags
#   KPORT_RUSTFLAGS     — Rust compiler flags
#   KPORT_LDFLAGS       — linker flags
#   KPORT_CMAKE_ARGS    — space-separated -DKEY=VALUE pairs for CMake
#   KPORT_MAKE_ARGS     — space-separated KEY=VALUE pairs for Make
#   KPORT_ARCH          — target arch (amd64|i386|arm64|riscv64)
#   KPORT_CROSS         — true if cross-compiling, false otherwise
#   KPORT_CROSS_TRIPLE  — GNU triple for cross toolchain (empty if native)
#   KPORT_GPU_BACKEND   — vulkan | opengl | opencl | software
#   KPORT_NPU_BACKEND   — none | opencl | intel-npu | amd-xdna | qualcomm-htp | cuda
#
# Arch support: amd64 (x86-64), i386 (i686), arm64 (aarch64), riscv64
#
# This file is managed by fork-sync-all/propagate-hw-detect.
# Source: https://github.com/Interested-Deving-1896/KPort

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse arguments ───────────────────────────────────────────────────────────

OUTPUT_MODE="source"   # source | export | cmake | json | make
CROSS_TARGET=""

for arg in "$@"; do
  case "$arg" in
    --export) OUTPUT_MODE="export" ;;
    --cmake)  OUTPUT_MODE="cmake"  ;;
    --json)   OUTPUT_MODE="json"   ;;
    --make)   OUTPUT_MODE="make"   ;;
    --cross)  shift; CROSS_TARGET="${1:-}" ;;
  esac
done

# ── Load hardware tiers ───────────────────────────────────────────────────────
# Priority: environment > hardware.conf > run detection

_load_hw_vars() {
  # Already set in environment — use them
  if [[ -n "${CPU_TIER:-}" && -n "${GPU_TIER:-}" && -n "${NPU_TIER:-}" ]]; then
    return 0
  fi

  # Try hardware.conf
  local conf="${KPORT_HARDWARE_CONF:-${HOME}/.config/kport/hardware.conf}"
  if [[ -f "$conf" ]]; then
    # shellcheck source=/dev/null
    source "$conf"
    return 0
  fi

  # Fall back to running detection
  if [[ -f "${SCRIPT_DIR}/kport-detect.sh" ]]; then
    eval "$(bash "${SCRIPT_DIR}/kport-detect.sh" --export 2>/dev/null)"
    return 0
  fi

  echo "[kport-build-flags] WARNING: no hardware.conf and no kport-detect.sh found" >&2
  CPU_TIER="${CPU_TIER:-x86-64-v1}"
  GPU_TIER="${GPU_TIER:-gpu-sw}"
  NPU_TIER="${NPU_TIER:-npu-none}"
}

_load_hw_vars

CPU_TIER="${CPU_TIER:-x86-64-v1}"
GPU_TIER="${GPU_TIER:-gpu-sw}"
NPU_TIER="${NPU_TIER:-npu-none}"
CPU_CORES="${CPU_CORES:-$(nproc 2>/dev/null || echo 1)}"

# ── Determine target arch ─────────────────────────────────────────────────────

_arch_from_tier() {
  case "$1" in
    x86-64-*)    echo "amd64" ;;
    i686-*)      echo "i386"  ;;
    aarch64-*)   echo "arm64" ;;
    riscv64-*)   echo "riscv64" ;;
    *)           uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/' ;;
  esac
}

KPORT_ARCH="${CROSS_TARGET:-$(_arch_from_tier "$CPU_TIER")}"
KPORT_CROSS="false"
KPORT_CROSS_TRIPLE=""

if [[ -n "$CROSS_TARGET" && "$CROSS_TARGET" != "$(_arch_from_tier "$CPU_TIER")" ]]; then
  KPORT_CROSS="true"
  case "$CROSS_TARGET" in
    i386)    KPORT_CROSS_TRIPLE="i686-linux-gnu" ;;
    arm64)   KPORT_CROSS_TRIPLE="aarch64-linux-gnu" ;;
    riscv64) KPORT_CROSS_TRIPLE="riscv64-linux-gnu" ;;
    amd64)   KPORT_CROSS_TRIPLE="x86_64-linux-gnu" ;;
  esac
fi

# ── CPU flags ─────────────────────────────────────────────────────────────────

_cpu_march() {
  local tier="${1:-$CPU_TIER}"
  case "$tier" in
    # x86-64 tiers — use -march=x86-64-vN (GCC 11+ / Clang 12+)
    x86-64-v4)  echo "-march=x86-64-v4 -mtune=native" ;;
    x86-64-v3)  echo "-march=x86-64-v3 -mtune=native" ;;
    x86-64-v2)  echo "-march=x86-64-v2 -mtune=native" ;;
    x86-64-v1)  echo "-march=x86-64    -mtune=generic" ;;
    # i686 tiers — 32-bit, no x86-64 extensions
    i686-sse3)      echo "-march=i686 -msse3 -mssse3 -mtune=generic -m32" ;;
    i686-baseline)  echo "-march=i686 -msse2 -mtune=generic -m32" ;;
    # aarch64 tiers
    aarch64-v9.2)  echo "-march=armv9.2-a+sme+sve2 -mtune=generic-armv9-a" ;;
    aarch64-v9)    echo "-march=armv9-a+sve2         -mtune=generic-armv9-a" ;;
    aarch64-v8.2)  echo "-march=armv8.2-a+dotprod+fp16+sve -mtune=generic-armv8-a" ;;
    aarch64-v8)    echo "-march=armv8-a              -mtune=generic-armv8-a" ;;
    # riscv64 tiers
    riscv64-rv64gcv) echo "-march=rv64gcv -mabi=lp64d" ;;
    riscv64-rv64gc)  echo "-march=rv64gc  -mabi=lp64d" ;;
    # cross-compile targets (no -mtune=native)
    *)  echo "-march=native -mtune=native" ;;
  esac
}

_cpu_rust_target() {
  local tier="${1:-$CPU_TIER}"
  case "$tier" in
    x86-64-v4)   echo "x86_64-unknown-linux-gnu" ;;
    x86-64-v3)   echo "x86_64-unknown-linux-gnu" ;;
    x86-64-v2)   echo "x86_64-unknown-linux-gnu" ;;
    x86-64-v1)   echo "x86_64-unknown-linux-gnu" ;;
    i686-*)      echo "i686-unknown-linux-gnu" ;;
    aarch64-*)   echo "aarch64-unknown-linux-gnu" ;;
    riscv64-*)   echo "riscv64gc-unknown-linux-gnu" ;;
    *)           echo "" ;;
  esac
}

_cpu_rust_flags() {
  local tier="${1:-$CPU_TIER}"
  case "$tier" in
    x86-64-v4)  echo "-C target-cpu=x86-64-v4" ;;
    x86-64-v3)  echo "-C target-cpu=x86-64-v3" ;;
    x86-64-v2)  echo "-C target-cpu=x86-64-v2" ;;
    x86-64-v1)  echo "-C target-cpu=x86-64" ;;
    i686-sse3)  echo "-C target-cpu=core2 -C target-feature=+sse3,+ssse3" ;;
    i686-baseline) echo "-C target-cpu=pentium4" ;;
    aarch64-v9.2)  echo "-C target-cpu=generic -C target-feature=+v9.2a,+sme,+sve2" ;;
    aarch64-v9)    echo "-C target-cpu=generic -C target-feature=+v9a,+sve2" ;;
    aarch64-v8.2)  echo "-C target-cpu=generic -C target-feature=+v8.2a,+dotprod,+fp16,+sve" ;;
    aarch64-v8)    echo "-C target-cpu=generic" ;;
    riscv64-rv64gcv) echo "-C target-cpu=generic-rv64 -C target-feature=+v" ;;
    riscv64-rv64gc)  echo "-C target-cpu=generic-rv64" ;;
    *)           echo "" ;;
  esac
}

# ── GPU flags ─────────────────────────────────────────────────────────────────

_gpu_backend() {
  case "${GPU_TIER:-gpu-sw}" in
    gpu-vk13|gpu-vk12|gpu-immortalis-*|gpu-adreno-7xx)
      echo "vulkan" ;;
    gpu-gl4|gpu-mali-*|gpu-adreno-6xx|gpu-img-bxm)
      echo "opengl" ;;
    gpu-gl2)
      echo "opengl" ;;
    *)
      echo "software" ;;
  esac
}

_gpu_cmake_args() {
  local backend
  backend=$(_gpu_backend)
  local args=()
  case "$backend" in
    vulkan)
      args+=("-DUSE_VULKAN=ON" "-DUSE_OPENGL=ON" "-DUSE_OPENCL=ON")
      # Vulkan not available on i386
      [[ "$KPORT_ARCH" == "i386" ]] && args=("-DUSE_VULKAN=OFF" "-DUSE_OPENGL=ON" "-DUSE_OPENCL=ON")
      ;;
    opengl)
      args+=("-DUSE_VULKAN=OFF" "-DUSE_OPENGL=ON" "-DUSE_OPENCL=ON")
      ;;
    software)
      args+=("-DUSE_VULKAN=OFF" "-DUSE_OPENGL=OFF" "-DUSE_OPENCL=OFF")
      ;;
  esac
  # VAAPI — available on Intel/AMD x86-64 and aarch64 with Mesa
  if echo "${GPU_FLAGS:-}" | grep -q "vaapi"; then
    args+=("-DUSE_VAAPI=ON")
  else
    args+=("-DUSE_VAAPI=OFF")
  fi
  echo "${args[*]}"
}

# ── NPU flags ─────────────────────────────────────────────────────────────────

_npu_backend() {
  case "${NPU_TIER:-npu-none}" in
    npu-none)       echo "none" ;;
    npu-igpu)       echo "opencl" ;;
    npu-dedicated|npu-ai|npu-datacenter)
      if echo "${NPU_FLAGS:-}" | grep -q "intel-npu";    then echo "intel-npu"
      elif echo "${NPU_FLAGS:-}" | grep -q "amd-xdna";   then echo "amd-xdna"
      elif echo "${NPU_FLAGS:-}" | grep -q "qualcomm-htp"; then echo "qualcomm-htp"
      elif echo "${NPU_FLAGS:-}" | grep -q "cuda-tensor"; then echo "cuda"
      else echo "opencl"
      fi ;;
    *)  echo "none" ;;
  esac
}

_npu_cmake_args() {
  local backend
  backend=$(_npu_backend)
  case "$backend" in
    none)         echo "-DUSE_NPU=OFF" ;;
    opencl)       echo "-DUSE_NPU=ON -DNPU_BACKEND=opencl" ;;
    intel-npu)    echo "-DUSE_NPU=ON -DNPU_BACKEND=intel-npu -DUSE_OPENVINO=ON" ;;
    amd-xdna)     echo "-DUSE_NPU=ON -DNPU_BACKEND=amd-xdna  -DUSE_ROCM=ON" ;;
    qualcomm-htp) echo "-DUSE_NPU=ON -DNPU_BACKEND=qualcomm-htp -DUSE_QNN=ON" ;;
    cuda)         echo "-DUSE_NPU=ON -DNPU_BACKEND=cuda -DUSE_CUDA=ON" ;;
    *)            echo "-DUSE_NPU=OFF" ;;
  esac
}

# ── Assemble final flag sets ──────────────────────────────────────────────────

_base_cflags() {
  local march
  march=$(_cpu_march "$CPU_TIER")
  local flags="$march -pipe -fstack-protector-strong"

  # Parallelism hint (not a compiler flag but useful for Make/Ninja)
  # LTO for v3+ and aarch64-v8.2+ (enough CPU to afford it)
  case "$CPU_TIER" in
    x86-64-v3|x86-64-v4|aarch64-v8.2|aarch64-v9|aarch64-v9.2|riscv64-rv64gcv)
      flags="$flags -flto=auto -fuse-linker-plugin"
      ;;
  esac

  # i386: disable SSE for strict ABI compat, enable only what the tier supports
  case "$CPU_TIER" in
    i686-baseline) flags="$flags -mfpmath=sse -msse2" ;;
    i686-sse3)     flags="$flags -mfpmath=sse -msse3 -mssse3" ;;
  esac

  echo "$flags"
}

_base_ldflags() {
  local flags="-Wl,-z,relro -Wl,-z,now -Wl,--as-needed"
  # LTO linker plugin
  case "$CPU_TIER" in
    x86-64-v3|x86-64-v4|aarch64-v8.2|aarch64-v9|aarch64-v9.2|riscv64-rv64gcv)
      flags="$flags -flto=auto"
      ;;
  esac
  echo "$flags"
}

KPORT_CFLAGS="$(_base_cflags)"
KPORT_CXXFLAGS="$(_base_cflags)"
KPORT_RUSTFLAGS="$(_cpu_rust_flags "$CPU_TIER")"
KPORT_LDFLAGS="$(_base_ldflags)"
KPORT_GPU_BACKEND="$(_gpu_backend)"
KPORT_NPU_BACKEND="$(_npu_backend)"

# Cross-compile: override march with target arch baseline, add cross triple
if [[ "$KPORT_CROSS" == "true" && -n "$KPORT_CROSS_TRIPLE" ]]; then
  case "$CROSS_TARGET" in
    i386)
      KPORT_CFLAGS="-march=i686 -msse2 -m32 -pipe -fstack-protector-strong"
      KPORT_CXXFLAGS="$KPORT_CFLAGS"
      KPORT_RUSTFLAGS="-C target-cpu=pentium4"
      ;;
    arm64)
      KPORT_CFLAGS="-march=armv8-a -mtune=generic-armv8-a -pipe -fstack-protector-strong"
      KPORT_CXXFLAGS="$KPORT_CFLAGS"
      KPORT_RUSTFLAGS="-C target-cpu=generic"
      ;;
    riscv64)
      KPORT_CFLAGS="-march=rv64gc -mabi=lp64d -pipe -fstack-protector-strong"
      KPORT_CXXFLAGS="$KPORT_CFLAGS"
      KPORT_RUSTFLAGS="-C target-cpu=generic-rv64"
      ;;
  esac
  KPORT_LDFLAGS="-Wl,-z,relro -Wl,-z,now -Wl,--as-needed"
fi

# Assemble CMake and Make args
KPORT_CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release"
KPORT_CMAKE_ARGS="$KPORT_CMAKE_ARGS -DCMAKE_C_FLAGS='${KPORT_CFLAGS}'"
KPORT_CMAKE_ARGS="$KPORT_CMAKE_ARGS -DCMAKE_CXX_FLAGS='${KPORT_CXXFLAGS}'"
KPORT_CMAKE_ARGS="$KPORT_CMAKE_ARGS -DCMAKE_EXE_LINKER_FLAGS='${KPORT_LDFLAGS}'"
KPORT_CMAKE_ARGS="$KPORT_CMAKE_ARGS $(_gpu_cmake_args)"
KPORT_CMAKE_ARGS="$KPORT_CMAKE_ARGS $(_npu_cmake_args)"
KPORT_CMAKE_ARGS="$KPORT_CMAKE_ARGS -DKPORT_CPU_TIER=${CPU_TIER}"
KPORT_CMAKE_ARGS="$KPORT_CMAKE_ARGS -DKPORT_GPU_TIER=${GPU_TIER}"
KPORT_CMAKE_ARGS="$KPORT_CMAKE_ARGS -DKPORT_NPU_TIER=${NPU_TIER}"
[[ "$KPORT_CROSS" == "true" ]] && \
  KPORT_CMAKE_ARGS="$KPORT_CMAKE_ARGS -DCMAKE_SYSTEM_PROCESSOR=${CROSS_TARGET} -DCMAKE_CROSSCOMPILING=ON"

KPORT_MAKE_ARGS="CFLAGS='${KPORT_CFLAGS}' CXXFLAGS='${KPORT_CXXFLAGS}' LDFLAGS='${KPORT_LDFLAGS}'"
KPORT_MAKE_ARGS="$KPORT_MAKE_ARGS KPORT_CPU_TIER=${CPU_TIER} KPORT_GPU_TIER=${GPU_TIER} KPORT_NPU_TIER=${NPU_TIER}"

# ── Output ────────────────────────────────────────────────────────────────────

case "$OUTPUT_MODE" in
  source)
    echo "KPORT_CFLAGS='${KPORT_CFLAGS}'"
    echo "KPORT_CXXFLAGS='${KPORT_CXXFLAGS}'"
    echo "KPORT_RUSTFLAGS='${KPORT_RUSTFLAGS}'"
    echo "KPORT_LDFLAGS='${KPORT_LDFLAGS}'"
    echo "KPORT_CMAKE_ARGS='${KPORT_CMAKE_ARGS}'"
    echo "KPORT_MAKE_ARGS='${KPORT_MAKE_ARGS}'"
    echo "KPORT_ARCH='${KPORT_ARCH}'"
    echo "KPORT_CROSS='${KPORT_CROSS}'"
    echo "KPORT_CROSS_TRIPLE='${KPORT_CROSS_TRIPLE}'"
    echo "KPORT_GPU_BACKEND='${KPORT_GPU_BACKEND}'"
    echo "KPORT_NPU_BACKEND='${KPORT_NPU_BACKEND}'"
    ;;
  export)
    echo "export KPORT_CFLAGS='${KPORT_CFLAGS}'"
    echo "export KPORT_CXXFLAGS='${KPORT_CXXFLAGS}'"
    echo "export KPORT_RUSTFLAGS='${KPORT_RUSTFLAGS}'"
    echo "export KPORT_LDFLAGS='${KPORT_LDFLAGS}'"
    echo "export KPORT_CMAKE_ARGS='${KPORT_CMAKE_ARGS}'"
    echo "export KPORT_MAKE_ARGS='${KPORT_MAKE_ARGS}'"
    echo "export KPORT_ARCH='${KPORT_ARCH}'"
    echo "export KPORT_CROSS='${KPORT_CROSS}'"
    echo "export KPORT_CROSS_TRIPLE='${KPORT_CROSS_TRIPLE}'"
    echo "export KPORT_GPU_BACKEND='${KPORT_GPU_BACKEND}'"
    echo "export KPORT_NPU_BACKEND='${KPORT_NPU_BACKEND}'"
    ;;
  cmake)
    echo "${KPORT_CMAKE_ARGS}"
    ;;
  make)
    echo "${KPORT_MAKE_ARGS}"
    ;;
  json)
    python3 - << PYEOF
import json
print(json.dumps({
  "KPORT_CFLAGS":        "${KPORT_CFLAGS}",
  "KPORT_CXXFLAGS":      "${KPORT_CXXFLAGS}",
  "KPORT_RUSTFLAGS":     "${KPORT_RUSTFLAGS}",
  "KPORT_LDFLAGS":       "${KPORT_LDFLAGS}",
  "KPORT_CMAKE_ARGS":    "${KPORT_CMAKE_ARGS}",
  "KPORT_ARCH":          "${KPORT_ARCH}",
  "KPORT_CROSS":         "${KPORT_CROSS}",
  "KPORT_CROSS_TRIPLE":  "${KPORT_CROSS_TRIPLE}",
  "KPORT_GPU_BACKEND":   "${KPORT_GPU_BACKEND}",
  "KPORT_NPU_BACKEND":   "${KPORT_NPU_BACKEND}",
  "CPU_TIER":            "${CPU_TIER}",
  "GPU_TIER":            "${GPU_TIER}",
  "NPU_TIER":            "${NPU_TIER}"
}, indent=2))
PYEOF
    ;;
esac
