#!/usr/bin/env bash
#
# KPort NPU/AI accelerator compatibility detection.
# Determines NPU tier and capability flags for on-device AI inference.
#
# Outputs shell variable assignments:
#   NPU_TIER    — npu-none | npu-igpu | npu-dedicated | npu-ai | npu-datacenter
#   NPU_FLAGS   — space-separated: opencl intel-npu amd-xdna qualcomm-htp cuda-tensor
#   NPU_MODEL   — NPU/accelerator model name
#   NPU_TOPS    — estimated TOPS (0 if unknown)
#
# Detection sources by arch:
#   i686 / x86-64:
#     1. /dev/accel/*        — Linux accelerator device nodes (kernel 6.2+)
#     2. intel_vpu/intel_npu — Intel NPU (Meteor Lake, Lunar Lake, Arrow Lake)
#     3. amdxdna             — AMD XDNA (Ryzen AI, Strix Point)
#     4. nvidia-smi          — NVIDIA Tensor Cores
#     5. clinfo              — OpenCL compute (iGPU fallback)
#   aarch64 / arm64:
#     1. /dev/accel/*        — Linux accelerator device nodes
#     2. Qualcomm HTP        — /dev/qaic*, qcom-npu driver
#     3. ARM Ethos / Apple ANE / MediaTek APU / Samsung NPU
#     4. clinfo              — OpenCL compute (iGPU fallback)
#   riscv64:
#     1. /dev/accel/*        — Linux accelerator device nodes
#     2. clinfo              — OpenCL compute (iGPU fallback)
#   i686 note: Intel NPU and AMD XDNA are x86-64-only silicon in practice.
#     On i686 hardware (pre-2010 era) NPU_TIER will almost always be npu-none.
#
# Usage:
#   source <(bash scripts/kport/kport-detect-npu.sh)
#   bash scripts/kport/kport-detect-npu.sh --export
#   bash scripts/kport/kport-detect-npu.sh --json

set -uo pipefail

EXPORT_MODE=false
JSON_MODE=false
for arg in "$@"; do
  [[ "$arg" == "--export" ]] && EXPORT_MODE=true
  [[ "$arg" == "--json"   ]] && JSON_MODE=true
done

NPU_TIER="npu-none"
NPU_FLAGS=""
NPU_MODEL="None"
NPU_TOPS="0"

declare -a npu_flags=()

# ── Intel NPU detection ───────────────────────────────────────────────────────
# Intel NPU present on Meteor Lake (Core Ultra 1xx), Lunar Lake (Core Ultra 2xx),
# Arrow Lake. Exposed via /dev/accel/accel0 and the intel_vpu kernel driver.

detect_intel_npu() {
  # Check for Intel VPU/NPU kernel driver
  if lsmod 2>/dev/null | grep -q 'intel_vpu\|intel_npu'; then
    NPU_TIER="npu-dedicated"
    npu_flags+=("intel-npu")

    # Identify generation from CPU model
    local cpu_model
    cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null \
      | sed 's/.*: //' | tr '[:upper:]' '[:lower:]')

    if echo "$cpu_model" | grep -qE 'ultra [12][0-9]{2}|meteor lake|lunar lake|arrow lake'; then
      NPU_TIER="npu-ai"
      # Meteor Lake: ~10 TOPS, Lunar Lake: ~48 TOPS, Arrow Lake: ~13 TOPS
      if echo "$cpu_model" | grep -qi 'lunar lake\|ultra 2'; then
        NPU_TOPS="48"
        NPU_MODEL="Intel NPU (Lunar Lake)"
      elif echo "$cpu_model" | grep -qi 'arrow lake'; then
        NPU_TOPS="13"
        NPU_MODEL="Intel NPU (Arrow Lake)"
      else
        NPU_TOPS="10"
        NPU_MODEL="Intel NPU (Meteor Lake)"
      fi
    else
      NPU_MODEL="Intel VPU/NPU"
      NPU_TOPS="10"
    fi
    return 0
  fi

  # Check /dev/accel/ device nodes (kernel 6.2+ accelerator subsystem)
  if ls /dev/accel/accel* &>/dev/null 2>&1; then
    for accel in /dev/accel/accel*; do
      local driver
      driver=$(readlink -f "/sys/class/accel/$(basename "$accel")/device/driver" \
        2>/dev/null | xargs basename 2>/dev/null || echo "")
      if [[ "$driver" == *"intel"* || "$driver" == *"vpu"* || "$driver" == *"npu"* ]]; then
        NPU_TIER="npu-dedicated"
        NPU_MODEL="Intel Accelerator (${driver})"
        NPU_TOPS="10"
        npu_flags+=("intel-npu")
        return 0
      fi
    done
  fi

  return 1
}

# ── AMD XDNA detection ────────────────────────────────────────────────────────
# AMD XDNA NPU present on Ryzen AI (Phoenix, Hawk Point), Strix Point (Ryzen AI 300).

detect_amd_xdna() {
  if lsmod 2>/dev/null | grep -q 'amdxdna\|amd_ipu'; then
    NPU_TIER="npu-ai"
    npu_flags+=("amd-xdna")

    local cpu_model
    cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null \
      | sed 's/.*: //' | tr '[:upper:]' '[:lower:]')

    if echo "$cpu_model" | grep -qiE 'ryzen ai 3[0-9]{2}|strix'; then
      NPU_TOPS="50"
      NPU_MODEL="AMD XDNA2 (Strix Point)"
    elif echo "$cpu_model" | grep -qiE 'ryzen ai|phoenix|hawk point'; then
      NPU_TOPS="16"
      NPU_MODEL="AMD XDNA (Ryzen AI)"
    else
      NPU_TOPS="16"
      NPU_MODEL="AMD XDNA NPU"
    fi
    return 0
  fi

  # Check via amdxdna sysfs
  if [[ -d /sys/bus/platform/drivers/amdxdna ]]; then
    NPU_TIER="npu-ai"
    NPU_MODEL="AMD XDNA NPU"
    NPU_TOPS="16"
    npu_flags+=("amd-xdna")
    return 0
  fi

  return 1
}

# ── NVIDIA Tensor Core detection ──────────────────────────────────────────────

detect_nvidia_tensor() {
  command -v nvidia-smi &>/dev/null || return 1
  nvidia-smi &>/dev/null || return 1

  local gpu_name compute_cap
  gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  compute_cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1)

  [[ -z "$gpu_name" ]] && return 1

  npu_flags+=("cuda-tensor")

  # Determine tier from compute capability
  # 7.0+ = Volta (Tensor Cores gen1), 8.0+ = Ampere (gen3), 9.0+ = Hopper
  local major
  major=$(echo "$compute_cap" | cut -d. -f1)

  if [[ "$major" -ge 9 ]]; then
    NPU_TIER="npu-datacenter"
    NPU_TOPS="3958"   # H100 SXM
    NPU_MODEL="NVIDIA ${gpu_name} (Hopper)"
  elif [[ "$major" -ge 8 ]]; then
    # Ampere: RTX 30xx consumer vs A100 datacenter
    if echo "$gpu_name" | grep -qiE 'A100|A30|A40|A6000'; then
      NPU_TIER="npu-datacenter"
      NPU_TOPS="312"
    else
      NPU_TIER="npu-ai"
      NPU_TOPS="82"   # RTX 3090 approximate
    fi
    NPU_MODEL="NVIDIA ${gpu_name} (Ampere)"
  elif [[ "$major" -ge 7 ]]; then
    NPU_TIER="npu-dedicated"
    NPU_TOPS="14"   # RTX 2080 approximate
    NPU_MODEL="NVIDIA ${gpu_name} (Turing/Volta)"
  else
    NPU_TIER="npu-igpu"
    NPU_TOPS="0"
    NPU_MODEL="NVIDIA ${gpu_name}"
  fi

  return 0
}

# ── Qualcomm HTP detection ────────────────────────────────────────────────────

detect_qualcomm_htp() {
  if ls /dev/qaic* &>/dev/null 2>&1 || \
     [[ -d /sys/bus/platform/drivers/qcom-npu ]] || \
     lsmod 2>/dev/null | grep -q 'qcom_npu\|qaic'; then
    NPU_TIER="npu-ai"
    NPU_MODEL="Qualcomm HTP/NPU"
    NPU_TOPS="15"
    npu_flags+=("qualcomm-htp")
    return 0
  fi
  return 1
}

# ── ARM NPU detection ─────────────────────────────────────────────────────────

detect_arm_npu() {
  # ── Apple Neural Engine (ANE) — M-series / A-series SoCs ─────────────────
  # Detected via device tree compatible or the ane kernel driver (Asahi Linux).
  if lsmod 2>/dev/null | grep -q '^ane\b' || \
     find /sys/firmware/devicetree/base -name 'compatible' 2>/dev/null \
       | xargs grep -ql 'apple,ane\|apple,h11-ane' 2>/dev/null; then
    NPU_TIER="npu-ai"
    NPU_MODEL="Apple Neural Engine"
    NPU_TOPS="38"   # M3 ANE; M1=11 TOPS, M2=15.8 TOPS, M3=18 TOPS (per-cluster)
    npu_flags+=("apple-ane")
    return 0
  fi

  # ── Arm Ethos-N78 / N57 (high-tier ML IP, npu-ai) ────────────────────────
  # Ethos-N78 is found in Samsung Exynos 2200+, MediaTek Dimensity 9000+.
  # Kernel driver: ethosn; device tree: arm,ethos-n78 or arm,ethos-n57
  if find /sys/firmware/devicetree/base -name 'compatible' 2>/dev/null \
       | xargs grep -ql 'arm,ethos-n78\|arm,ethos-n57' 2>/dev/null || \
     find /sys/bus/platform/devices -name 'ethosn*' 2>/dev/null | grep -q .; then
    NPU_TIER="npu-ai"
    NPU_MODEL="Arm Ethos-N78"
    NPU_TOPS="4"
    npu_flags+=("arm-npu" "ethos-n78")
    return 0
  fi

  # ── Arm Ethos-N (generic / Ethos-N37/N57/N77, npu-dedicated) ─────────────
  if lsmod 2>/dev/null | grep -q 'ethosn\|arm_npu' || \
     find /sys/firmware/devicetree/base -name 'compatible' 2>/dev/null \
       | xargs grep -ql 'arm,ethos-n' 2>/dev/null; then
    NPU_TIER="npu-dedicated"
    NPU_MODEL="Arm Ethos-N NPU"
    NPU_TOPS="4"
    npu_flags+=("arm-npu")
    return 0
  fi

  # ── Arm Ethos-U (microNPU, embedded Cortex-M class, npu-dedicated) ────────
  # Ethos-U55/U65 appear in Cortex-M55/M85 subsystems; unlikely on KDE Neon
  # targets but included for completeness.
  if find /sys/firmware/devicetree/base -name 'compatible' 2>/dev/null \
       | xargs grep -ql 'arm,ethos-u' 2>/dev/null; then
    NPU_TIER="npu-dedicated"
    NPU_MODEL="Arm Ethos-U microNPU"
    NPU_TOPS="1"
    npu_flags+=("arm-npu" "ethos-u")
    return 0
  fi

  # ── MediaTek APU (AI Processing Unit, npu-dedicated / npu-ai) ────────────
  # Found in Dimensity SoCs. Driver: mtk_apu or vpu (older).
  if lsmod 2>/dev/null | grep -q 'mtk_apu\|mtk_vpu\|vpu_service' || \
     find /sys/firmware/devicetree/base -name 'compatible' 2>/dev/null \
       | xargs grep -ql 'mediatek,apu\|mediatek,vpu' 2>/dev/null; then
    # Dimensity 9000+ APU 590 ≈ npu-ai; older APU 3xx ≈ npu-dedicated
    local apu_gen
    apu_gen=$(find /sys/firmware/devicetree/base -name 'compatible' 2>/dev/null \
      | xargs grep -h 'mediatek,apu' 2>/dev/null | grep -oP 'apu\d+' | head -1)
    if [[ "${apu_gen:-0}" =~ apu[5-9] ]]; then
      NPU_TIER="npu-ai"
      NPU_TOPS="10"
    else
      NPU_TIER="npu-dedicated"
      NPU_TOPS="4"
    fi
    NPU_MODEL="MediaTek APU"
    npu_flags+=("mtk-apu")
    return 0
  fi

  # ── Samsung Exynos NPU (npu-dedicated) ───────────────────────────────────
  if lsmod 2>/dev/null | grep -q 'exynos_npu\|npu_exynos' || \
     find /sys/firmware/devicetree/base -name 'compatible' 2>/dev/null \
       | xargs grep -ql 'samsung,exynos-npu' 2>/dev/null; then
    NPU_TIER="npu-dedicated"
    NPU_MODEL="Samsung Exynos NPU"
    NPU_TOPS="5"
    npu_flags+=("exynos-npu")
    return 0
  fi

  return 1
}

# ── OpenCL iGPU fallback ──────────────────────────────────────────────────────
# If no dedicated NPU found but OpenCL is available via iGPU, classify as npu-igpu

detect_opencl_igpu() {
  command -v clinfo &>/dev/null || return 1

  local platform_count
  platform_count=$(clinfo 2>/dev/null | grep 'Number of platforms' \
    | grep -oP '\d+' | head -1)

  [[ "${platform_count:-0}" -gt 0 ]] || return 1

  NPU_TIER="npu-igpu"
  NPU_MODEL="OpenCL iGPU compute"
  NPU_TOPS="0"
  npu_flags+=("opencl")
  return 0
}

# ── Run detection ─────────────────────────────────────────────────────────────
#
# Detectors are gated by arch family to avoid running ARM-specific probes on
# x86 hardware and vice versa.  The OpenCL iGPU fallback runs on all arches.

ARCH=$(uname -m)

case "$ARCH" in
  i686|i586|i486|i386)
    # 32-bit x86: Intel NPU and AMD XDNA are x86-64-only silicon — no i686
    # CPU ships with an integrated NPU.  NVIDIA Tensor Cores are possible on
    # discrete GPUs connected via PCIe.  OpenCL via iGPU is the realistic
    # ceiling on most i686 hardware.
    detect_nvidia_tensor || \
    detect_opencl_igpu   || \
    true
    ;;
  x86_64)
    detect_intel_npu     || \
    detect_amd_xdna      || \
    detect_nvidia_tensor || \
    detect_opencl_igpu   || \
    true
    ;;
  aarch64|arm64)
    detect_qualcomm_htp  || \
    detect_arm_npu       || \
    detect_opencl_igpu   || \
    true
    ;;
  riscv64)
    # No production RISC-V NPU drivers exist yet; OpenCL is the only path.
    detect_opencl_igpu   || \
    true
    ;;
  *)
    # Unknown arch — try everything, fail gracefully to npu-none.
    detect_intel_npu     || \
    detect_amd_xdna      || \
    detect_nvidia_tensor || \
    detect_qualcomm_htp  || \
    detect_arm_npu       || \
    detect_opencl_igpu   || \
    true
    ;;
esac

NPU_FLAGS="${npu_flags[*]:-}"

# ── Output ────────────────────────────────────────────────────────────────────

raw_output="NPU_TIER=\"${NPU_TIER}\""$'\n'
raw_output+="NPU_FLAGS=\"${NPU_FLAGS}\""$'\n'
raw_output+="NPU_MODEL=\"${NPU_MODEL}\""$'\n'
raw_output+="NPU_TOPS=\"${NPU_TOPS}\""

if [[ "$JSON_MODE" == "true" ]]; then
  printf '{"npu_tier":"%s","npu_flags":"%s","npu_model":"%s","npu_tops":%s}\n' \
    "$NPU_TIER" "$NPU_FLAGS" "${NPU_MODEL//\"/\\\"}" "$NPU_TOPS"
elif [[ "$EXPORT_MODE" == "true" ]]; then
  echo "$raw_output" | sed 's/^/export /'
else
  echo "$raw_output"
fi
