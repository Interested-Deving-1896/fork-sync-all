#!/usr/bin/env bash
#
# KPort GPU compatibility detection.
# Determines GPU tier, vendor, and capability flags.
# Supports x86-64 (PCI), i686 (legacy PCI / VESA), aarch64 (ARM SoC), and riscv64 (SoC).
#
# Outputs shell variable assignments:
#   GPU_TIER      — capability tier (see below)
#   GPU_VENDOR    — gpu-intel | gpu-amd | gpu-nvidia | gpu-nvidia-proprietary
#                   gpu-mali | gpu-immortalis | gpu-powervr | gpu-adreno
#                   gpu-apple | gpu-unknown
#   GPU_FLAGS     — space-separated capability flags (vulkan, vaapi, opencl, …)
#   GPU_MODEL     — human-readable GPU model string
#   GPU_VRAM_MB   — VRAM in MiB (0 if unknown / unified memory)
#
# GPU tier definitions (unified capability scale):
#
#   i686 / legacy x86 GPU tiers:
#     gpu-sw        software rendering / VESA framebuffer only
#     gpu-gl2       OpenGL 2.x (legacy discrete, e.g. GeForce 6/7, Radeon X series)
#     gpu-gl4       OpenGL 4.x (Intel HD 2000+, AMD GCN, NVIDIA Fermi+ with Mesa)
#                   Vulkan drivers do not ship for 32-bit userspace; gl4 is the ceiling.
#
#   x86-64 / discrete GPU tiers:
#     gpu-sw        software rendering only (llvmpipe / no GPU)
#     gpu-gl2       OpenGL 2.x (legacy integrated, very old discrete)
#     gpu-gl4       OpenGL 4.x / Vulkan 1.0-1.1 (modern integrated, mid discrete)
#     gpu-vk12      Vulkan 1.2 (recent discrete / high-end integrated)
#     gpu-vk13      Vulkan 1.3 (current-gen discrete)
#
#   ARM SoC GPU tiers:
#     gpu-mali-g52        Mali-G52/G57 Valhall entry (Vulkan 1.1, OpenGL ES 3.2)
#     gpu-mali-g610       Mali-G610/G715 Valhall mid (Vulkan 1.2)
#     gpu-immortalis-g715 Immortalis-G715/G720 (Vulkan 1.3, hardware ray-tracing)
#     gpu-adreno-6xx      Adreno 6xx (Vulkan 1.1, Qualcomm SoCs)
#     gpu-adreno-7xx      Adreno 7xx (Vulkan 1.3, Snapdragon 8 Gen 2+)
#
#   RISC-V SoC GPU tiers:
#     gpu-img-bxm         PowerVR BXM-8-256 (JH7110 / StarFive, Vulkan 1.0)
#
# Usage:
#   source <(bash scripts/kport/kport-detect-gpu.sh)
#   bash scripts/kport/kport-detect-gpu.sh --export
#   bash scripts/kport/kport-detect-gpu.sh --json

set -uo pipefail

EXPORT_MODE=false
JSON_MODE=false
for arg in "$@"; do
  [[ "$arg" == "--export" ]] && EXPORT_MODE=true
  [[ "$arg" == "--json"   ]] && JSON_MODE=true
done

# ── Defaults ──────────────────────────────────────────────────────────────────

GPU_TIER="gpu-sw"
GPU_VENDOR="gpu-unknown"
GPU_FLAGS=""
GPU_MODEL="Unknown GPU"
GPU_VRAM_MB=0

# ── x86-64 vendor detection (PCI) ────────────────────────────────────────────

detect_vendor_from_drm() {
  for card in /sys/class/drm/card*/device/vendor; do
    [[ -f "$card" ]] || continue
    local vendor_id
    vendor_id=$(cat "$card" 2>/dev/null)
    case "$vendor_id" in
      0x8086) echo "gpu-intel";  return ;;
      0x1002) echo "gpu-amd";    return ;;
      0x10de) echo "gpu-nvidia"; return ;;
    esac
  done
  echo "gpu-unknown"
}

detect_vendor_from_lspci() {
  command -v lspci &>/dev/null || { echo "gpu-unknown"; return; }
  local pci_out
  pci_out=$(lspci 2>/dev/null | grep -iE 'VGA|3D|Display')
  if   echo "$pci_out" | grep -qi 'intel';                    then echo "gpu-intel";  return; fi
  if   echo "$pci_out" | grep -qi 'amd\|radeon\|advanced micro'; then echo "gpu-amd"; return; fi
  if   echo "$pci_out" | grep -qi 'nvidia';                   then echo "gpu-nvidia"; return; fi
  echo "gpu-unknown"
}

detect_model_from_drm() {
  for card in /sys/class/drm/card*/device; do
    local label
    label=$(cat "$card/label" 2>/dev/null \
      || cat "$card/product_name" 2>/dev/null \
      || cat "$card/../product_name" 2>/dev/null) || true
    [[ -n "$label" ]] && echo "$label" && return
  done
  if command -v lspci &>/dev/null; then
    lspci 2>/dev/null | grep -iE 'VGA|3D|Display' | head -1 \
      | sed 's/.*: //' | head -c 80
    return
  fi
  echo "Unknown GPU"
}

# ── ARM/RISC-V SoC GPU detection ─────────────────────────────────────────────
#
# On SoC platforms, GPU info comes from:
#   1. DRM driver name in /sys/class/drm/card*/device/driver/module/
#   2. Device tree compatible strings in /sys/bus/platform/drivers/
#   3. /proc/device-tree/gpu* or /sys/firmware/devicetree/base/
#   4. /sys/kernel/debug/dri/*/name (requires root, best-effort)

_drm_driver_name() {
  # Returns the DRM driver name for the first card, e.g. "panfrost", "msm", "pvr"
  for card in /sys/class/drm/card*/device/driver; do
    [[ -L "$card" ]] && basename "$(readlink -f "$card")" && return
  done
  # Fallback: /sys/class/drm/card0/device/uevent
  local uevent
  uevent=$(cat /sys/class/drm/card0/device/uevent 2>/dev/null)
  echo "$uevent" | grep -i 'DRIVER=' | cut -d= -f2 | head -1
}

_dt_compatible() {
  # Read device tree compatible strings for GPU nodes.
  #
  # Source 1: upstream kernels expose the full DT under /sys/firmware/devicetree.
  local dt_strings=""
  dt_strings=$(
    find /sys/firmware/devicetree/base -name 'compatible' 2>/dev/null \
      | xargs grep -ail 'mali\|panfrost\|powervr\|pvr\|adreno\|msm\|apple-agx\|img' \
        2>/dev/null | head -5 \
      | xargs -r cat 2>/dev/null | tr '\0' '\n' | tr '[:upper:]' '[:lower:]'
  )

  # Source 2: downstream/vendor kernels (QCOM, Android-derived) often omit
  # /sys/firmware/devicetree entirely but still expose OF_COMPATIBLE in the
  # platform device uevent.  Scan all platform device uevents for GPU-related
  # OF_COMPATIBLE entries.  The field is NUL-separated on older kernels and
  # newline-separated on newer ones; normalise both.
  local uevent_strings=""
  uevent_strings=$(
    grep -rl 'OF_COMPATIBLE' /sys/bus/platform/devices/*/uevent 2>/dev/null \
      | xargs grep -h 'OF_COMPATIBLE' 2>/dev/null \
      | grep -iE 'adreno|msm|mali|panfrost|powervr|pvr|apple-agx|img' \
      | sed 's/OF_COMPATIBLE[_0-9]*=//g' \
      | tr '[:upper:]' '[:lower:]' \
      | tr '\0' '\n'
  )

  # Source 3: DRM card uevent — some downstream kernels set OF_COMPATIBLE here
  # even when the platform bus entries are absent.
  local drm_uevent_strings=""
  drm_uevent_strings=$(
    for uevent_path in /sys/class/drm/card*/device/uevent; do
      [[ -f "$uevent_path" ]] || continue
      grep 'OF_COMPATIBLE' "$uevent_path" 2>/dev/null \
        | sed 's/OF_COMPATIBLE[_0-9]*=//g' \
        | tr '[:upper:]' '[:lower:]' \
        | tr '\0' '\n'
    done
  )

  printf '%s\n%s\n%s\n' "$dt_strings" "$uevent_strings" "$drm_uevent_strings" \
    | grep -v '^$' | sort -u
}

detect_soc_gpu() {
  local drm_driver
  drm_driver=$(_drm_driver_name | tr '[:upper:]' '[:lower:]')

  local dt_compat
  dt_compat=$(_dt_compatible)

  # ── Immortalis (ARM, ray-tracing, Vulkan 1.3) ─────────────────────────────
  # Immortalis-G715, G720 — panfrost driver, compatible "arm,mali-valhall-csf"
  # or model string contains "immortalis"
  if echo "$dt_compat" | grep -qi 'immortalis\|mali-valhall-csf'; then
    GPU_TIER="gpu-immortalis-g715"
    GPU_VENDOR="gpu-immortalis"
    GPU_MODEL=$(echo "$dt_compat" | grep -i 'immortalis' | head -1 \
      | sed 's/.*,//' | tr '-' ' ' | head -c 60 || echo "ARM Immortalis")
    return 0
  fi

  # ── Mali Valhall mid (G610, G715 non-Immortalis, Vulkan 1.2) ──────────────
  # Compatible strings: arm,mali-valhall or specific G6xx/G7xx part numbers
  if echo "$dt_compat" | grep -qiE 'mali-g6[1-9][0-9]|mali-g7[0-9][0-9]|mali-valhall[^-]'; then
    GPU_TIER="gpu-mali-g610"
    GPU_VENDOR="gpu-mali"
    GPU_MODEL=$(echo "$dt_compat" | grep -iE 'mali-g[67]' | head -1 \
      | sed 's/.*,//' | tr '-' ' ' | head -c 60 || echo "ARM Mali Valhall")
    return 0
  fi

  # ── Mali Valhall entry / Bifrost (G52, G57, G76, Vulkan 1.1) ─────────────
  # panfrost driver covers Midgard (T6xx/T7xx/T8xx), Bifrost (G31/G51/G52/G76),
  # and Valhall entry (G57). We classify G52+ as gpu-mali-g52.
  if [[ "$drm_driver" == "panfrost" ]] || \
     echo "$dt_compat" | grep -qiE 'mali-g[3-5][0-9]|mali-bifrost|mali-t[6-9]'; then
    # Try to distinguish G52+ from older Midgard/Bifrost
    if echo "$dt_compat" | grep -qiE 'mali-g5[0-9]|mali-g4[0-9]'; then
      GPU_TIER="gpu-mali-g52"
    else
      GPU_TIER="gpu-gl4"   # Older Bifrost/Midgard — OpenGL ES 3.2 capable
    fi
    GPU_VENDOR="gpu-mali"
    GPU_MODEL=$(echo "$dt_compat" | grep -i 'mali' | head -1 \
      | sed 's/.*,//' | tr '-' ' ' | head -c 60 || echo "ARM Mali")
    return 0
  fi

  # ── Adreno 7xx (Qualcomm, Vulkan 1.3, Snapdragon 8 Gen 2+) ───────────────
  if echo "$dt_compat" | grep -qiE 'adreno[,_-]7[0-9][0-9]|qcom,adreno-7'; then
    GPU_TIER="gpu-adreno-7xx"
    GPU_VENDOR="gpu-adreno"
    GPU_MODEL=$(echo "$dt_compat" | grep -i 'adreno' | head -1 \
      | sed 's/.*,//' | tr '-' ' ' | head -c 60 || echo "Qualcomm Adreno 7xx")
    return 0
  fi

  # ── Adreno 6xx (Qualcomm, Vulkan 1.1, Snapdragon 8xx/7xx) ────────────────
  if [[ "$drm_driver" == "msm" ]] || \
     echo "$dt_compat" | grep -qiE 'adreno[,_-]6[0-9][0-9]|qcom,adreno'; then
    GPU_TIER="gpu-adreno-6xx"
    GPU_VENDOR="gpu-adreno"
    GPU_MODEL=$(echo "$dt_compat" | grep -i 'adreno' | head -1 \
      | sed 's/.*,//' | tr '-' ' ' | head -c 60 || echo "Qualcomm Adreno 6xx")
    return 0
  fi

  # ── PowerVR / Imagination (RISC-V JH7110, Vulkan 1.0) ────────────────────
  # pvr driver (upstream 6.2+) or img-rogue out-of-tree driver
  if [[ "$drm_driver" == "pvr" || "$drm_driver" == "img-rogue" ]] || \
     echo "$dt_compat" | grep -qiE 'powervr|img,.*gpu|bxm-8-256'; then
    GPU_TIER="gpu-img-bxm"
    GPU_VENDOR="gpu-powervr"
    GPU_MODEL=$(echo "$dt_compat" | grep -iE 'powervr|img.*gpu|bxm' | head -1 \
      | sed 's/.*,//' | tr '-' ' ' | head -c 60 || echo "PowerVR BXM")
    return 0
  fi

  # ── Apple AGX (M-series, Vulkan via MoltenVK / Asahi) ────────────────────
  if [[ "$drm_driver" == "asahi" ]] || \
     echo "$dt_compat" | grep -qi 'apple,agx\|apple-agx'; then
    GPU_TIER="gpu-vk13"   # AGX G13/G14 is Vulkan 1.3 capable via Asahi
    GPU_VENDOR="gpu-apple"
    GPU_MODEL="Apple AGX"
    return 0
  fi

  return 1   # No SoC GPU detected
}

# ── Vulkan detection ──────────────────────────────────────────────────────────

detect_via_vulkan() {
  command -v vulkaninfo &>/dev/null || return 1
  local vk_out
  vk_out=$(vulkaninfo --summary 2>/dev/null) || return 1

  local vk_version
  vk_version=$(echo "$vk_out" | grep -i 'apiVersion\|Vulkan Instance Version' \
    | grep -oP '\d+\.\d+' | head -1)

  local major minor
  major=$(echo "$vk_version" | cut -d. -f1)
  minor=$(echo "$vk_version" | cut -d. -f2)

  # Only override tier if we haven't already set an ARM/RISC-V tier
  if [[ "$GPU_TIER" == "gpu-sw" || "$GPU_TIER" == "gpu-gl"* ]]; then
    if   [[ "$major" -ge 1 && "$minor" -ge 3 ]]; then GPU_TIER="gpu-vk13"
    elif [[ "$major" -ge 1 && "$minor" -ge 2 ]]; then GPU_TIER="gpu-vk12"
    elif [[ "$major" -ge 1 ]];                   then GPU_TIER="gpu-gl4"
    fi
  fi

  local gpu_name
  gpu_name=$(echo "$vk_out" | grep -i 'deviceName\|GPU id' \
    | head -1 | sed 's/.*= //' | sed 's/.*: //' | tr -s ' ' | head -c 80)
  [[ -n "$gpu_name" && "$GPU_MODEL" == "Unknown GPU" ]] && GPU_MODEL="$gpu_name"

  local vram
  vram=$(echo "$vk_out" | grep -i 'heapSize\|VRAM' \
    | grep -oP '\d+' | sort -rn | head -1)
  if [[ -n "$vram" && "$vram" -gt 1000000 ]]; then
    GPU_VRAM_MB=$(( vram / 1024 / 1024 ))
  fi

  return 0
}

# ── OpenGL detection (fallback) ───────────────────────────────────────────────

detect_via_opengl() {
  command -v glxinfo &>/dev/null || return 1
  local gl_out
  gl_out=$(glxinfo 2>/dev/null) || return 1

  local gl_version
  gl_version=$(echo "$gl_out" | grep 'OpenGL version string' \
    | grep -oP '\d+\.\d+' | head -1)

  local major
  major=$(echo "$gl_version" | cut -d. -f1)

  if [[ "$GPU_TIER" == "gpu-sw" ]]; then
    if   [[ "$major" -ge 4 ]]; then GPU_TIER="gpu-gl4"
    elif [[ "$major" -ge 2 ]]; then GPU_TIER="gpu-gl2"
    fi
  fi

  local gpu_name
  gpu_name=$(echo "$gl_out" | grep 'OpenGL renderer string' \
    | sed 's/.*: //' | head -c 80)
  [[ -n "$gpu_name" && "$GPU_MODEL" == "Unknown GPU" ]] && GPU_MODEL="$gpu_name"

  return 0
}

# ── Capability flag detection ─────────────────────────────────────────────────

detect_capability_flags() {
  local flags=()

  # Vulkan
  case "$GPU_TIER" in
    gpu-vk*|gpu-immortalis*|gpu-adreno-7xx|gpu-mali-g610) flags+=("vulkan") ;;
    gpu-mali-g52|gpu-adreno-6xx|gpu-img-bxm) flags+=("vulkan") ;;  # Vulkan 1.0/1.1
  esac

  # VA-API (Intel/AMD hardware video decode, also some ARM via v4l2)
  if command -v vainfo &>/dev/null; then
    vainfo &>/dev/null 2>&1 && flags+=("vaapi")
  elif [[ -e /dev/dri/renderD128 ]] && \
       [[ "$GPU_VENDOR" == "gpu-intel" || "$GPU_VENDOR" == "gpu-amd" ]]; then
    flags+=("vaapi")
  fi

  # VDPAU (NVIDIA legacy)
  if command -v vdpauinfo &>/dev/null; then
    vdpauinfo &>/dev/null 2>&1 && flags+=("vdpau")
  fi

  # ROCm (AMD compute)
  if command -v rocm-smi &>/dev/null || [[ -d /opt/rocm ]]; then
    flags+=("rocm")
  fi

  # NVIDIA proprietary / CUDA
  if command -v nvidia-smi &>/dev/null; then
    nvidia-smi &>/dev/null 2>&1 && {
      GPU_VENDOR="gpu-nvidia-proprietary"
      flags+=("cuda")
    }
  fi

  # OpenCL
  if command -v clinfo &>/dev/null; then
    clinfo 2>/dev/null | grep -q 'Number of platforms.*[1-9]' && flags+=("opencl")
  fi

  # OpenGL ES (ARM/RISC-V SoC GPUs always support GLES)
  case "$GPU_VENDOR" in
    gpu-mali|gpu-immortalis|gpu-adreno|gpu-powervr) flags+=("gles") ;;
  esac

  GPU_FLAGS="${flags[*]:-}"
}

# ── i686 / legacy x86 GPU detection ──────────────────────────────────────────
#
# On 32-bit x86 we use the same PCI vendor detection as x86-64, but cap the
# tier at gpu-gl4: no Vulkan driver ships a 32-bit (i686) userspace library.
# If no DRM device is found at all, fall back to gpu-sw (VESA framebuffer).
#
# Tier assignment heuristic:
#   - Intel i965 (Gen4+) and later → gpu-gl4 via Mesa i965/iris
#   - Intel i830–i915 (Gen2/3)     → gpu-gl2
#   - AMD GCN (Radeon HD 7000+)    → gpu-gl4 via Mesa radeonsi
#   - AMD pre-GCN (Radeon X/HD2000–6000) → gpu-gl2 via Mesa r300/r600
#   - NVIDIA Fermi+ (GTX 400+)     → gpu-gl4 via Nouveau
#   - NVIDIA pre-Fermi             → gpu-gl2 via Nouveau
#   - No DRM device / VESA only    → gpu-sw

detect_i686_gpu() {
  # Vendor detection reuses the existing PCI helpers.
  GPU_VENDOR=$(detect_vendor_from_drm)
  [[ "$GPU_VENDOR" == "gpu-unknown" ]] && GPU_VENDOR=$(detect_vendor_from_lspci)
  GPU_MODEL=$(detect_model_from_drm)

  # If no DRM device exists at all, we're on VESA or a pure framebuffer.
  if [[ "$GPU_VENDOR" == "gpu-unknown" ]] && \
     ! ls /sys/class/drm/card* &>/dev/null 2>&1; then
    GPU_TIER="gpu-sw"
    GPU_VENDOR="gpu-unknown"
    GPU_MODEL="VESA / framebuffer"
    return 0
  fi

  # Use glxinfo to determine the actual OpenGL version available.
  # On i686 this is the most reliable signal — PCI IDs alone don't tell us
  # which Mesa version is installed or whether the driver is loaded.
  if command -v glxinfo &>/dev/null; then
    local gl_out gl_version major
    gl_out=$(glxinfo 2>/dev/null) || true
    gl_version=$(echo "$gl_out" | grep 'OpenGL version string' \
      | grep -oP '\d+\.\d+' | head -1)
    major=$(echo "$gl_version" | cut -d. -f1)
    case "$major" in
      4|3) GPU_TIER="gpu-gl4" ;;  # gl4 is the ceiling on i686
      2)   GPU_TIER="gpu-gl2" ;;
      *)   GPU_TIER="gpu-sw"  ;;
    esac
    local gpu_name
    gpu_name=$(echo "$gl_out" | grep 'OpenGL renderer string' \
      | sed 's/.*: //' | head -c 80)
    [[ -n "$gpu_name" ]] && GPU_MODEL="$gpu_name"
    return 0
  fi

  # glxinfo unavailable — fall back to PCI vendor heuristics.
  # These are conservative: we'd rather under-report than over-promise.
  case "$GPU_VENDOR" in
    gpu-intel)
      # Check PCI device ID range to distinguish Gen2/3 (gl2) from Gen4+ (gl4).
      # Gen4+ device IDs start at 0x2972 (i965 G).  We use lspci class 0300.
      local intel_id
      intel_id=$(lspci -n 2>/dev/null | grep ' 0300: 8086:' \
        | grep -oP '8086:\K[0-9a-fA-F]+' | head -1)
      if [[ -n "$intel_id" ]]; then
        local id_dec
        id_dec=$(printf '%d' "0x${intel_id}" 2>/dev/null || echo 0)
        # Gen4 starts at 0x2972 (decimal 10610)
        [[ "$id_dec" -ge 10610 ]] && GPU_TIER="gpu-gl4" || GPU_TIER="gpu-gl2"
      else
        GPU_TIER="gpu-gl2"
      fi
      ;;
    gpu-amd)
      # GCN starts with Radeon HD 7000 series (device IDs 0x6798+).
      local amd_id
      amd_id=$(lspci -n 2>/dev/null | grep ' 0300: 1002:' \
        | grep -oP '1002:\K[0-9a-fA-F]+' | head -1)
      if [[ -n "$amd_id" ]]; then
        local id_dec
        id_dec=$(printf '%d' "0x${amd_id}" 2>/dev/null || echo 0)
        # GCN first device ID 0x6798 (decimal 26520)
        [[ "$id_dec" -ge 26520 ]] && GPU_TIER="gpu-gl4" || GPU_TIER="gpu-gl2"
      else
        GPU_TIER="gpu-gl2"
      fi
      ;;
    gpu-nvidia)
      # Fermi starts at GF100 (device IDs 0x06C0+).
      local nv_id
      nv_id=$(lspci -n 2>/dev/null | grep ' 0300: 10de:' \
        | grep -oP '10de:\K[0-9a-fA-F]+' | head -1)
      if [[ -n "$nv_id" ]]; then
        local id_dec
        id_dec=$(printf '%d' "0x${nv_id}" 2>/dev/null || echo 0)
        # Fermi GF100 0x06C0 (decimal 1728)
        [[ "$id_dec" -ge 1728 ]] && GPU_TIER="gpu-gl4" || GPU_TIER="gpu-gl2"
      else
        GPU_TIER="gpu-gl2"
      fi
      ;;
    *)
      GPU_TIER="gpu-sw"
      ;;
  esac
}

# ── Run detection ─────────────────────────────────────────────────────────────

ARCH=$(uname -m)

case "$ARCH" in
  aarch64|arm64|riscv64)
    # SoC path: try device-tree / DRM driver first
    if ! detect_soc_gpu; then
      # No DT match — fall through to Vulkan/GL probing
      detect_via_vulkan || detect_via_opengl || true
    else
      # SoC GPU found — still run Vulkan to refine tier if available
      detect_via_vulkan || true
    fi
    # Vendor still unknown after SoC detection → try PCI (e.g. ARM board with PCIe GPU)
    if [[ "$GPU_VENDOR" == "gpu-unknown" ]]; then
      GPU_VENDOR=$(detect_vendor_from_drm)
      [[ "$GPU_VENDOR" == "gpu-unknown" ]] && GPU_VENDOR=$(detect_vendor_from_lspci)
      GPU_MODEL=$(detect_model_from_drm)
      detect_via_vulkan || detect_via_opengl || true
    fi
    ;;
  i686|i586|i486|i386)
    # 32-bit x86: PCI vendor + GL probing, capped at gpu-gl4.
    # Vulkan detection is skipped — no 32-bit Vulkan ICD ships in practice.
    detect_i686_gpu
    ;;
  *)
    # x86-64 and others: PCI vendor + Vulkan/GL
    GPU_VENDOR=$(detect_vendor_from_drm)
    [[ "$GPU_VENDOR" == "gpu-unknown" ]] && GPU_VENDOR=$(detect_vendor_from_lspci)
    GPU_MODEL=$(detect_model_from_drm)
    detect_via_vulkan || detect_via_opengl || true
    ;;
esac

detect_capability_flags

# ── Output ────────────────────────────────────────────────────────────────────

raw_output="GPU_TIER=\"${GPU_TIER}\""$'\n'
raw_output+="GPU_VENDOR=\"${GPU_VENDOR}\""$'\n'
raw_output+="GPU_FLAGS=\"${GPU_FLAGS}\""$'\n'
raw_output+="GPU_MODEL=\"${GPU_MODEL}\""$'\n'
raw_output+="GPU_VRAM_MB=\"${GPU_VRAM_MB}\""

if [[ "$JSON_MODE" == "true" ]]; then
  eval "$raw_output"
  printf '{"gpu_tier":"%s","gpu_vendor":"%s","gpu_flags":"%s","gpu_model":"%s","gpu_vram_mb":%s}\n' \
    "$GPU_TIER" "$GPU_VENDOR" "$GPU_FLAGS" "${GPU_MODEL//\"/\\\"}" "$GPU_VRAM_MB"
elif [[ "$EXPORT_MODE" == "true" ]]; then
  echo "$raw_output" | sed 's/^/export /'
else
  echo "$raw_output"
fi
