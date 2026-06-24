#!/usr/bin/env bash
#
# KPort hardware compatibility detection orchestrator.
# Runs CPU, GPU, and NPU detection, derives USE flags, and writes
# ~/.config/kport/hardware.conf (or $KPORT_HARDWARE_CONF if set).
#
# Usage:
#   kport detect                  # detect and write hardware.conf
#   kport detect --dry-run        # detect and print without writing
#   kport detect --update         # re-detect and overwrite existing conf
#   kport detect --show-flags     # show derived USE flags after detection
#   kport detect --json           # output JSON (implies --dry-run)
#   kport detect --export         # print export statements (implies --dry-run)
#
# The generated hardware.conf is read by:
#   - pacscripts at build time (sourced by kport-build.sh)
#   - kport-resolve.sh when computing effective USE flags
#   - kport-install.sh when selecting binary package variants

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────

KPORT_CONFIG_DIR="${KPORT_CONFIG_DIR:-${HOME}/.config/kport}"
KPORT_HARDWARE_CONF="${KPORT_HARDWARE_CONF:-${KPORT_CONFIG_DIR}/hardware.conf}"
KPORT_TEMPLATE="${KPORT_TEMPLATE:-$(cd "${SCRIPT_DIR}/../../" && pwd)/config/hardware.conf.tpl}"

DRY_RUN=false
UPDATE=false
SHOW_FLAGS=false
JSON_MODE=false
EXPORT_MODE=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=true ;;
    --update)     UPDATE=true ;;
    --show-flags) SHOW_FLAGS=true ;;
    --json)       JSON_MODE=true; DRY_RUN=true ;;
    --export)     EXPORT_MODE=true; DRY_RUN=true ;;
  esac
done

info()  { [[ "$JSON_MODE" == "false" ]] && echo "[kport detect] $*" || true; }
warn()  { [[ "$JSON_MODE" == "false" ]] && echo "[warn] $*" >&2 || true; }

# ── Check if conf already exists ─────────────────────────────────────────────

if [[ -f "$KPORT_HARDWARE_CONF" && "$UPDATE" != "true" && "$DRY_RUN" != "true" ]]; then
  info "hardware.conf already exists: ${KPORT_HARDWARE_CONF}"
  info "Use --update to re-detect and overwrite."
  exit 0
fi

# ── Run sub-detectors ─────────────────────────────────────────────────────────

info "Detecting CPU..."
eval "$(bash "${SCRIPT_DIR}/kport-detect-cpu.sh")"

info "Detecting GPU..."
eval "$(bash "${SCRIPT_DIR}/kport-detect-gpu.sh")"

info "Detecting NPU..."
eval "$(bash "${SCRIPT_DIR}/kport-detect-npu.sh")"

# ── Derive USE flags from hardware ────────────────────────────────────────────
# Reads config/use-flags.yml hardware: true entries and auto-sets them
# based on detected tiers and vendor flags.

derive_use_flags() {
  # Vulkan: auto-enable when GPU_TIER >= gpu-vk12
  case "${GPU_TIER:-gpu-sw}" in
    gpu-vk12|gpu-vk13) USE_VULKAN="true" ;;
    *)                  USE_VULKAN="false" ;;
  esac

  # OpenGL: disable only on pure software rendering
  case "${GPU_TIER:-gpu-sw}" in
    gpu-sw) USE_OPENGL="false" ;;
    *)      USE_OPENGL="true" ;;
  esac

  # VA-API: Intel or AMD GPU
  case "${GPU_VENDOR:-gpu-unknown}" in
    gpu-intel|gpu-amd) USE_VAAPI="true" ;;
    *)                  USE_VAAPI="false" ;;
  esac

  # VDPAU: NVIDIA (any)
  case "${GPU_VENDOR:-gpu-unknown}" in
    gpu-nvidia|gpu-nvidia-proprietary) USE_VDPAU="true" ;;
    *)                                  USE_VDPAU="false" ;;
  esac

  # CUDA: NVIDIA proprietary only
  case "${GPU_VENDOR:-gpu-unknown}" in
    gpu-nvidia-proprietary) USE_CUDA="true" ;;
    *)                       USE_CUDA="false" ;;
  esac

  # ROCm: AMD with ROCm flag
  if echo "${GPU_FLAGS:-}" | grep -qw "rocm"; then
    USE_ROCM="true"
  else
    USE_ROCM="false"
  fi

  # OpenCL: NPU tier >= npu-igpu or GPU has opencl flag
  case "${NPU_TIER:-npu-none}" in
    npu-igpu|npu-dedicated|npu-ai|npu-datacenter) USE_OPENCL="true" ;;
    *)
      if echo "${GPU_FLAGS:-}" | grep -qw "opencl"; then
        USE_OPENCL="true"
      else
        USE_OPENCL="false"
      fi
      ;;
  esac

  # NPU: dedicated NPU or better
  case "${NPU_TIER:-npu-none}" in
    npu-dedicated|npu-ai|npu-datacenter) USE_NPU="true" ;;
    *)                                    USE_NPU="false" ;;
  esac

  # Local LLM: NPU tier >= npu-ai (>=10 TOPS) or CUDA/ROCm available
  case "${NPU_TIER:-npu-none}" in
    npu-ai|npu-datacenter) USE_LLM_LOCAL="true" ;;
    *)
      if [[ "${USE_CUDA:-false}" == "true" || "${USE_ROCM:-false}" == "true" ]]; then
        USE_LLM_LOCAL="true"
      else
        USE_LLM_LOCAL="false"
      fi
      ;;
  esac
}

derive_use_flags

# ── Build hardware.conf from template ────────────────────────────────────────

build_conf() {
  local tpl
  if [[ -f "$KPORT_TEMPLATE" ]]; then
    tpl=$(cat "$KPORT_TEMPLATE")
  else
    # Inline fallback if template file not found
    tpl='# KPort hardware.conf — generated {{GENERATED_DATE}}
CPU_TIER="{{CPU_TIER}}"
CPU_FLAGS="{{CPU_FLAGS}}"
CPU_CORES="{{CPU_CORES}}"
CPU_MODEL="{{CPU_MODEL}}"
GPU_TIER="{{GPU_TIER}}"
GPU_VENDOR="{{GPU_VENDOR}}"
GPU_FLAGS="{{GPU_FLAGS}}"
GPU_MODEL="{{GPU_MODEL}}"
GPU_VRAM_MB="{{GPU_VRAM_MB}}"
NPU_TIER="{{NPU_TIER}}"
NPU_FLAGS="{{NPU_FLAGS}}"
NPU_MODEL="{{NPU_MODEL}}"
NPU_TOPS="{{NPU_TOPS}}"
USE_VULKAN="{{USE_VULKAN}}"
USE_VAAPI="{{USE_VAAPI}}"
USE_VDPAU="{{USE_VDPAU}}"
USE_CUDA="{{USE_CUDA}}"
USE_ROCM="{{USE_ROCM}}"
USE_OPENCL="{{USE_OPENCL}}"
USE_NPU="{{USE_NPU}}"
USE_LLM_LOCAL="{{USE_LLM_LOCAL}}"'
  fi

  local date_str
  date_str=$(date -u '+%Y-%m-%d %H:%M UTC')

  echo "$tpl" \
    | sed "s|{{GENERATED_DATE}}|${date_str}|g" \
    | sed "s|{{CPU_TIER}}|${CPU_TIER:-unknown}|g" \
    | sed "s|{{CPU_FLAGS}}|${CPU_FLAGS:-}|g" \
    | sed "s|{{CPU_CORES}}|${CPU_CORES:-1}|g" \
    | sed "s|{{CPU_MODEL}}|${CPU_MODEL:-Unknown}|g" \
    | sed "s|{{GPU_TIER}}|${GPU_TIER:-gpu-sw}|g" \
    | sed "s|{{GPU_VENDOR}}|${GPU_VENDOR:-gpu-unknown}|g" \
    | sed "s|{{GPU_FLAGS}}|${GPU_FLAGS:-}|g" \
    | sed "s|{{GPU_MODEL}}|${GPU_MODEL:-Unknown}|g" \
    | sed "s|{{GPU_VRAM_MB}}|${GPU_VRAM_MB:-0}|g" \
    | sed "s|{{NPU_TIER}}|${NPU_TIER:-npu-none}|g" \
    | sed "s|{{NPU_FLAGS}}|${NPU_FLAGS:-}|g" \
    | sed "s|{{NPU_MODEL}}|${NPU_MODEL:-None}|g" \
    | sed "s|{{NPU_TOPS}}|${NPU_TOPS:-0}|g" \
    | sed "s|{{USE_VULKAN}}|${USE_VULKAN:-false}|g" \
    | sed "s|{{USE_VAAPI}}|${USE_VAAPI:-false}|g" \
    | sed "s|{{USE_VDPAU}}|${USE_VDPAU:-false}|g" \
    | sed "s|{{USE_CUDA}}|${USE_CUDA:-false}|g" \
    | sed "s|{{USE_ROCM}}|${USE_ROCM:-false}|g" \
    | sed "s|{{USE_OPENCL}}|${USE_OPENCL:-false}|g" \
    | sed "s|{{USE_NPU}}|${USE_NPU:-false}|g" \
    | sed "s|{{USE_LLM_LOCAL}}|${USE_LLM_LOCAL:-false}|g"
}

conf_content=$(build_conf)

# ── Output ────────────────────────────────────────────────────────────────────

if [[ "$JSON_MODE" == "true" ]]; then
  printf '{
  "cpu": %s,
  "gpu": %s,
  "npu": %s,
  "use_flags": {
    "vulkan": %s, "opengl": %s, "vaapi": %s, "vdpau": %s,
    "cuda": %s, "rocm": %s, "opencl": %s, "npu": %s, "llm_local": %s
  }
}\n' \
    "$(bash "${SCRIPT_DIR}/kport-detect-cpu.sh" --json)" \
    "$(bash "${SCRIPT_DIR}/kport-detect-gpu.sh" --json)" \
    "$(bash "${SCRIPT_DIR}/kport-detect-npu.sh" --json)" \
    "${USE_VULKAN:-false}" "${USE_OPENGL:-true}" "${USE_VAAPI:-false}" \
    "${USE_VDPAU:-false}" "${USE_CUDA:-false}" "${USE_ROCM:-false}" \
    "${USE_OPENCL:-false}" "${USE_NPU:-false}" "${USE_LLM_LOCAL:-false}"
  exit 0
fi

if [[ "$EXPORT_MODE" == "true" ]]; then
  bash "${SCRIPT_DIR}/kport-detect-cpu.sh" --export
  bash "${SCRIPT_DIR}/kport-detect-gpu.sh" --export
  bash "${SCRIPT_DIR}/kport-detect-npu.sh" --export
  exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "=== hardware.conf (dry run — not written) ==="
  echo "$conf_content"
  echo "============================================="
else
  mkdir -p "$KPORT_CONFIG_DIR"
  echo "$conf_content" > "$KPORT_HARDWARE_CONF"
  info "Written: ${KPORT_HARDWARE_CONF}"
fi

if [[ "$SHOW_FLAGS" == "true" || "$DRY_RUN" == "true" ]]; then
  echo ""
  info "Derived USE flags:"
  info "  vulkan=${USE_VULKAN:-false}  opengl=${USE_OPENGL:-true}"
  info "  vaapi=${USE_VAAPI:-false}    vdpau=${USE_VDPAU:-false}"
  info "  cuda=${USE_CUDA:-false}      rocm=${USE_ROCM:-false}"
  info "  opencl=${USE_OPENCL:-false}  npu=${USE_NPU:-false}"
  info "  llm-local=${USE_LLM_LOCAL:-false}"
fi

info ""
info "Summary:"
info "  CPU: ${CPU_TIER:-unknown} — ${CPU_MODEL:-Unknown} (${CPU_CORES:-?} cores)"
info "  GPU: ${GPU_TIER:-gpu-sw} — ${GPU_MODEL:-Unknown} [${GPU_VENDOR:-unknown}]"
info "  NPU: ${NPU_TIER:-npu-none} — ${NPU_MODEL:-None} (${NPU_TOPS:-0} TOPS)"
