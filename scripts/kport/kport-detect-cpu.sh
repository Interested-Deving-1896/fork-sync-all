#!/usr/bin/env bash
#
# KPort CPU compatibility detection.
# Determines the CPU microarchitecture tier and feature flags.
# Supports x86-64, i686, aarch64 (ARM), and riscv64.
#
# Outputs shell variable assignments suitable for sourcing or writing
# to hardware.conf:
#   CPU_ARCH    — x86-64 | i686 | aarch64 | riscv64 | unknown
#   CPU_TIER    — architecture-specific tier string (see below)
#   CPU_FLAGS   — space-separated list of notable CPU feature flags
#   CPU_MODEL   — human-readable CPU model string
#   CPU_CORES   — logical core count
#
# i686 tier definitions (32-bit x86, ordered lowest → highest):
#   i686-baseline  Pentium 4 / Prescott minimum (SSE2, no x86-64)
#   i686-sse3      Core 2 era (SSE3 + SSSE3, still 32-bit)
#
# x86-64 tier definitions (from the x86-64 psABI):
#   x86-64-v1   baseline (cmov, cx8, fpu, fxsr, mmx, syscall, sse, sse2)
#   x86-64-v2   + cx16, lahf, popcnt, sse3, sse4.1, sse4.2, ssse3
#   x86-64-v3   + avx, avx2, bmi1, bmi2, f16c, fma, lzcnt, movbe, xsave
#   x86-64-v4   + avx512f, avx512bw, avx512cd, avx512dq, avx512vl
#
# aarch64 tier definitions:
#   aarch64-v8    ARMv8.0-A baseline (Cortex-A53/A55, all 64-bit ARM)
#   aarch64-v8.2  ARMv8.2-A (Cortex-A75/A76/A77, dotprod, fp16)
#   aarch64-v9    ARMv9.0-A (Cortex-A710/X2, SVE2, MTE)
#   aarch64-v9.2  ARMv9.2-A (Cortex-A720/X4, SME, FEAT_AFP)
#
# riscv64 tier definitions:
#   riscv64-rv64gc   RV64GC baseline (I+M+A+F+D+C extensions)
#   riscv64-rv64gcv  RV64GCV (+ V vector extension, e.g. SiFive X280, T-Head C910)
#
# Usage:
#   source <(bash scripts/kport/kport-detect-cpu.sh)
#   bash scripts/kport/kport-detect-cpu.sh --export   # prints export statements
#   bash scripts/kport/kport-detect-cpu.sh --json     # prints JSON

set -uo pipefail

EXPORT_MODE=false
JSON_MODE=false
for arg in "$@"; do
  [[ "$arg" == "--export" ]] && EXPORT_MODE=true
  [[ "$arg" == "--json"   ]] && JSON_MODE=true
done

# ── i686 detection ───────────────────────────────────────────────────────────
#
# 32-bit x86 kernels report "i686" (or i386/i486/i586) from uname -m.
# We classify into two tiers based on SSE3/SSSE3 availability:
#   i686-baseline  SSE2 present, no SSE3 (Pentium 4 Prescott, Celeron D)
#   i686-sse3      SSE3 + SSSE3 present (Core 2 Duo and later 32-bit CPUs)
#
# Note: x86-64 CPUs running a 32-bit kernel also land here.  The tier still
# reflects the instruction set available to 32-bit userspace.

detect_i686() {
  local tier="i686-baseline"

  local cpuflags
  cpuflags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | sed 's/flags\s*:\s*//')

  has_flag() { echo "$cpuflags" | grep -qw "$1"; }

  # SSE3 + SSSE3 → i686-sse3 (Core 2 era)
  if has_flag sse3 && has_flag ssse3; then
    tier="i686-sse3"
  fi

  local notable=()
  for f in sse sse2 sse3 ssse3 sse4_1 sse4_2 pae nx aes cx16 popcnt; do
    has_flag "$f" && notable+=("$f")
  done
  local flags="${notable[*]:-}"

  local cores model
  cores=$(nproc 2>/dev/null || echo "1")
  model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null \
    | sed 's/model name\s*:\s*//' | tr -s ' ' | head -c 80 || echo "Unknown i686")

  echo "CPU_ARCH=\"i686\""
  echo "CPU_TIER=\"${tier}\""
  echo "CPU_FLAGS=\"${flags}\""
  echo "CPU_CORES=\"${cores}\""
  echo "CPU_MODEL=\"${model}\""
}

# ── x86-64 detection ─────────────────────────────────────────────────────────

detect_x86_64() {
  local tier="x86-64-v1"
  local flags=""

  # Try x86-64-level tool first (most accurate)
  local x86_level_bin
  x86_level_bin=$(command -v x86-64-level 2>/dev/null \
    || find /usr/local/bin /usr/bin /opt -name 'x86-64-level' 2>/dev/null | head -1)

  if [[ -n "$x86_level_bin" ]]; then
    local level
    level=$("$x86_level_bin" 2>/dev/null) || level="1"
    tier="x86-64-v${level}"
  else
    local cpuflags
    cpuflags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | sed 's/flags\s*:\s*//')

    has_flag() { echo "$cpuflags" | grep -qw "$1"; }

    if has_flag sse3 && has_flag ssse3 && has_flag sse4_1 && \
       has_flag sse4_2 && has_flag popcnt && has_flag cx16; then
      tier="x86-64-v2"
      if has_flag avx && has_flag avx2 && has_flag bmi1 && \
         has_flag bmi2 && has_flag fma && has_flag movbe; then
        tier="x86-64-v3"
        if has_flag avx512f && has_flag avx512bw && has_flag avx512cd && \
           has_flag avx512dq && has_flag avx512vl; then
          tier="x86-64-v4"
        fi
      fi
    fi
  fi

  local cpuflags
  cpuflags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | sed 's/flags\s*:\s*//')
  local notable=()
  for f in avx avx2 avx512f fma bmi1 bmi2 aes sha_ni vaes vpclmulqdq \
            sse4_1 sse4_2 popcnt cx16 movbe xsave f16c lzcnt; do
    echo "$cpuflags" | grep -qw "$f" && notable+=("$f")
  done
  flags="${notable[*]:-}"

  local cores model
  cores=$(nproc 2>/dev/null || echo "1")
  model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null \
    | sed 's/model name\s*:\s*//' | tr -s ' ' | head -c 80 || echo "Unknown x86")

  echo "CPU_ARCH=\"x86-64\""
  echo "CPU_TIER=\"${tier}\""
  echo "CPU_FLAGS=\"${flags}\""
  echo "CPU_CORES=\"${cores}\""
  echo "CPU_MODEL=\"${model}\""
}

# ── aarch64 detection ─────────────────────────────────────────────────────────
#
# Tier classification uses /proc/cpuinfo Features flags.
#
# Feature flag mapping:
#   aarch64-v8.2  dotprod | asimdhp | atomics (FEAT_LSE)
#   aarch64-v9    sve2 | mte | (bf16 + i8mm)
#   aarch64-v9.2  sme | sme2

detect_aarch64() {
  local tier="aarch64-v8"

  local cpuflags
  cpuflags=$(grep -m1 '^Features' /proc/cpuinfo 2>/dev/null \
    | sed 's/Features\s*:\s*//')

  has_arm_flag() { echo "$cpuflags" | grep -qw "$1"; }

  if has_arm_flag sme || has_arm_flag sme2; then
    tier="aarch64-v9.2"
  elif has_arm_flag sve2 || has_arm_flag mte || \
       ( has_arm_flag bf16 && has_arm_flag i8mm ); then
    tier="aarch64-v9"
  elif has_arm_flag dotprod || has_arm_flag asimdhp || has_arm_flag atomics; then
    tier="aarch64-v8.2"
  fi

  local notable=()
  for f in dotprod asimdhp atomics dcpop sve sve2 bf16 i8mm mte sme sme2 \
            crc32 aes sha2 sha3 sm3 sm4 fp fphp asimd; do
    has_arm_flag "$f" && notable+=("$f")
  done
  local flags="${notable[*]:-}"

  local model
  model=$(grep -m1 '^Hardware\|^Processor\|^Model name' /proc/cpuinfo 2>/dev/null \
    | sed 's/.*:\s*//' | tr -s ' ' | head -c 80)
  if [[ -z "$model" ]] && [[ -r /sys/firmware/devicetree/base/model ]]; then
    model=$(tr -d '\0' < /sys/firmware/devicetree/base/model | head -c 80)
  fi
  [[ -z "$model" ]] && model="Unknown ARM"

  local cores
  cores=$(nproc 2>/dev/null || echo "1")

  echo "CPU_ARCH=\"aarch64\""
  echo "CPU_TIER=\"${tier}\""
  echo "CPU_FLAGS=\"${flags}\""
  echo "CPU_CORES=\"${cores}\""
  echo "CPU_MODEL=\"${model}\""
}

# ── riscv64 detection ─────────────────────────────────────────────────────────
#
# Tier classification uses the ISA string from /proc/cpuinfo (Linux 5.15+).
# Example ISA strings:
#   rv64imafdcsu_zicsr_zifencei          → rv64gc baseline
#   rv64imafdcvsu_zicsr_zifencei_zvl128b → rv64gcv (V extension present)
#
# V extension detection: 'v' in the single-letter block OR any zve* extension.

detect_riscv64() {
  local tier="riscv64-rv64gc"

  local isa_str
  isa_str=$(grep -m1 '^isa' /proc/cpuinfo 2>/dev/null \
    | sed 's/isa\s*:\s*//' | tr '[:upper:]' '[:lower:]')

  # Fallback: device tree riscv,isa property
  if [[ -z "$isa_str" ]]; then
    isa_str=$(find /sys/firmware/devicetree -name 'riscv,isa' 2>/dev/null \
      | head -1 | xargs -r cat 2>/dev/null | tr -d '\0' | tr '[:upper:]' '[:lower:]')
  fi

  # V vector: 'v' in single-letter block (rv64...v...) or any zve* extension
  if echo "$isa_str" | grep -qE '(^rv64[a-z]*v[a-z_]|_zve[0-9])'; then
    tier="riscv64-rv64gcv"
  fi

  # Collect notable extensions
  local notable=()
  for ext in zba zbb zbc zbs zkn zks zvl128b zvl256b zvl512b; do
    echo "$isa_str" | grep -qF "_${ext}" && notable+=("$ext")
  done
  # Single-letter extras
  for ext in v b h; do
    echo "$isa_str" | grep -qE "^rv64[a-z]*${ext}" && notable+=("$ext")
  done
  local flags="${notable[*]:-}"

  local model
  model=$(grep -m1 '^uarch\|^mmu-type' /proc/cpuinfo 2>/dev/null \
    | sed 's/.*:\s*//' | tr -s ' ' | head -c 80)
  if [[ -z "$model" ]] && [[ -r /sys/firmware/devicetree/base/model ]]; then
    model=$(tr -d '\0' < /sys/firmware/devicetree/base/model | head -c 80)
  fi
  [[ -z "$model" ]] && model="Unknown RISC-V"

  local cores
  cores=$(nproc 2>/dev/null || echo "1")

  echo "CPU_ARCH=\"riscv64\""
  echo "CPU_TIER=\"${tier}\""
  echo "CPU_FLAGS=\"${flags}\""
  echo "CPU_CORES=\"${cores}\""
  echo "CPU_MODEL=\"${model}\""
}

# ── Run detection ─────────────────────────────────────────────────────────────

ARCH=$(uname -m)
raw_output=""

case "$ARCH" in
  aarch64|arm64)    raw_output=$(detect_aarch64) ;;
  x86_64)           raw_output=$(detect_x86_64)  ;;
  riscv64)          raw_output=$(detect_riscv64) ;;
  i686|i586|i486|i386)
    # All 32-bit x86 variants are classified under the i686 tier system.
    # i386/i486/i586 are too old to run a modern Linux userspace in practice,
    # but we report them as i686-baseline rather than unknown.
    raw_output=$(detect_i686) ;;
  *)
    raw_output="CPU_ARCH=\"unknown\""$'\n'
    raw_output+="CPU_TIER=\"unknown\""$'\n'
    raw_output+="CPU_FLAGS=\"\""$'\n'
    raw_output+="CPU_CORES=\"$(nproc 2>/dev/null || echo 1)\""$'\n'
    raw_output+="CPU_MODEL=\"${ARCH}\""
    ;;
esac

# ── Output ────────────────────────────────────────────────────────────────────

if [[ "$JSON_MODE" == "true" ]]; then
  eval "$raw_output"
  printf '{"cpu_arch":"%s","cpu_tier":"%s","cpu_flags":"%s","cpu_cores":%s,"cpu_model":"%s"}\n' \
    "${CPU_ARCH:-unknown}" "${CPU_TIER}" "${CPU_FLAGS}" "${CPU_CORES}" \
    "${CPU_MODEL//\"/\\\"}"
elif [[ "$EXPORT_MODE" == "true" ]]; then
  echo "$raw_output" | sed 's/^/export /'
else
  echo "$raw_output"
fi
