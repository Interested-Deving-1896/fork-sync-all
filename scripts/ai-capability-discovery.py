#!/usr/bin/env python3
"""Read-only, provider-neutral discovery of locally visible AI compute capabilities."""
from __future__ import annotations
import argparse, importlib.util, json, os, platform, shutil, subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "1.0"
BACKENDS = {
    "cuda": ("nvidia-smi", "nvcc"), "rocm": ("rocminfo", "rocm-smi"),
    "openvino": ("benchmark_app", "ovc"), "onnxruntime": (),
    "vulkan": ("vulkaninfo",), "opencl": ("clinfo",),
    "qualcomm-qnn": ("qnn-onnx-converter", "qnn-net-run"),
    "android-nnapi": (), "apple-coreml": (), "apple-metal": (),
    "directml": (), "webnn": (),
}

def read_text(path: str, limit: int = 4096) -> str:
    try: return Path(path).read_text(encoding="utf-8", errors="replace")[:limit].strip()
    except OSError: return ""

def run_probe(args: list[str], timeout: float = 2.0) -> str:
    try:
        p = subprocess.run(args, check=False, capture_output=True, text=True, timeout=timeout)
        return (p.stdout or p.stderr).strip()[:4096]
    except (OSError, subprocess.SubprocessError): return ""

def detect_execution_context() -> dict[str, Any]:
    system, machine = platform.system().lower() or "unknown", platform.machine().lower() or "unknown"
    android = bool(os.environ.get("ANDROID_ROOT") or Path("/system/build.prop").exists() or shutil.which("getprop"))
    if android: system = "android"
    cgroup = read_text("/proc/1/cgroup", 8192).lower()
    containerized = any(Path(p).exists() for p in ("/.dockerenv", "/run/.containerenv")) or any(
        x in cgroup for x in ("docker", "containerd", "kubepods", "podman", "lxc"))
    environment = "mobile" if android else ("container" if containerized else "unknown")
    release = read_text("/proc/sys/kernel/osrelease", 1024).lower()
    if "microsoft" in release or "wsl" in release: environment = "wsl"
    virt = run_probe(["systemd-detect-virt"], 1.0)
    if virt and virt not in ("none", "failed") and environment == "unknown": environment = "virtual-machine"
    props = {}
    if android and shutil.which("getprop"):
        for key in ("ro.product.manufacturer", "ro.product.model", "ro.build.version.release", "ro.hardware"):
            value = run_probe(["getprop", key], 1.0)
            if value: props[key] = value
    return {"os": system, "os_release": platform.release() or "unknown",
            "architecture": machine, "python_bits": platform.architecture()[0],
            "execution_environment": environment, "containerized": containerized,
            "virtualization_hint": virt if virt and virt not in ("none", "failed") else "unknown",
            "android_properties": props, "target_architecture": None, "target_is_cross_compiled": False}

def discover_visible_devices() -> list[dict[str, Any]]:
    devices = []
    for raw, kind, label in [
        ("/dev/dri", "gpu", "DRM render/display devices"), ("/dev/accel", "npu", "Linux accelerator devices"),
        ("/dev/kfd", "gpu", "AMD compute device"), ("/dev/nvidia0", "gpu", "NVIDIA GPU device"),
        ("/dev/kgsl-3d0", "gpu", "Qualcomm Adreno device"), ("/dev/mali0", "gpu", "ARM Mali device"),
        ("/dev/ion", "accelerator", "Android shared-memory/accelerator interface")]:
        p = Path(raw)
        if p.is_dir():
            try: children = sorted(x for x in p.iterdir() if x.name.startswith(("card", "renderD", "accel")))
            except OSError: children = []
            for child in children:
                devices.append({"kind":kind,"path":str(child),"visible":True,"label":label,
                                "access":os.access(child,os.R_OK|os.W_OK)})
        elif p.exists():
            devices.append({"kind":kind,"path":raw,"visible":True,"label":label,
                            "access":os.access(p,os.R_OK|os.W_OK)})
    drm = Path("/sys/class/drm")
    if drm.is_dir():
        try:
            for entry in sorted(drm.glob("card[0-9]*")):
                vendor, device = read_text(str(entry/"device/vendor"),128), read_text(str(entry/"device/device"),128)
                if vendor or device:
                    devices.append({"kind":"gpu","sysfs":str(entry),"vendor_id":vendor or "unknown",
                                    "device_id":device or "unknown","visible":True,"label":"DRM sysfs device"})
        except OSError: pass
    return devices

def discover_runtime_candidates() -> list[dict[str, Any]]:
    result = []
    for backend, commands in BACKENDS.items():
        found = {cmd:shutil.which(cmd) for cmd in commands}
        installed = any(found.values())
        if backend == "android-nnapi": installed = platform.system().lower()=="android" or bool(os.environ.get("ANDROID_ROOT"))
        elif backend in ("apple-coreml","apple-metal"): installed = platform.system().lower()=="darwin"
        elif backend == "directml": installed = platform.system().lower()=="windows"
        elif backend == "onnxruntime":
            try: installed = importlib.util.find_spec("onnxruntime") is not None
            except (ImportError, ValueError): installed = False
        result.append({"id":backend,"installed":installed,"commands":{k:v for k,v in found.items() if v},
                       "state":"candidate" if installed else "not-detected","verified_usable":False,
                       "verification_note":"Presence detection only; backend/device execution has not been tested."})
    return result

def load_kport(path: str | None, run_kport: bool) -> dict[str, Any] | None:
    if path:
        try:
            data=json.loads(Path(path).read_text(encoding="utf-8"))
            return data if isinstance(data,dict) else None
        except (OSError,json.JSONDecodeError): return None
    if run_kport:
        detector=Path(__file__).resolve().parent/"kport"/"kport-detect.sh"
        if not detector.exists(): return None
        try:
            p=subprocess.run(["bash",str(detector),"--json"],check=False,capture_output=True,text=True,timeout=15)
            data=json.loads(p.stdout)
            return data if isinstance(data,dict) else None
        except (OSError,subprocess.SubprocessError,json.JSONDecodeError): return None
    return None

def build_inventory(kport: dict[str, Any] | None = None) -> dict[str, Any]:
    context, devices, runtimes = detect_execution_context(), discover_visible_devices(), discover_runtime_candidates()
    return {"schema_version":SCHEMA_VERSION,
            "observed_at":datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00","Z"),
            "observer":"fork-sync-all-ai-capability-discovery","read_only":True,
            "execution_context":context,
            "hardware":{"kport_profile":kport,"visible_devices":devices,
                        "device_visibility":"visible" if devices else "none-detected"},
            "runtimes":runtimes,
            "acceleration":{"verified_usable_backends":[],"candidate_backends":[r["id"] for r in runtimes if r["installed"]],
                            "default_fallback":"cpu",
                            "selection_policy":"Only verified_usable_backends may be selected for accelerated execution."},
            "limitations":[
                "Device nodes and runtime tools indicate visibility or presence, not working acceleration.",
                "No privileged host inspection, driver loading, installation, benchmark, network access, or telemetry is performed.",
                "A guest or container can report only resources visible to its current process.",
                "Hardware identifiers are limited to vendor/device IDs where available; serial numbers are not collected.",
                "OS-specific runtime verification requires separately reviewed adapters."]}

def main(argv: list[str] | None = None) -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json",action="store_true",help="emit normalized JSON")
    parser.add_argument("--kport-json",help="consume captured KPort --json profile")
    parser.add_argument("--run-kport",action="store_true",help="run existing KPort detector in read-only JSON mode")
    args=parser.parse_args(argv)
    if args.kport_json and args.run_kport: parser.error("choose either --kport-json or --run-kport")
    print(json.dumps(build_inventory(load_kport(args.kport_json,args.run_kport)),indent=2,sort_keys=True))
    return 0

if __name__ == "__main__": raise SystemExit(main())
