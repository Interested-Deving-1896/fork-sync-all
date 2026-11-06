# AI hardware and runtime capability discovery

This AI-Agent-Neutral Engine capability inventories compute resources visible to
the current Fork-Sync-All process. It reuses KPort for CPU/GPU/NPU classification
and adds a normalized agent-facing view of execution context, device visibility,
and runtime candidates.

## Run

```bash
python3 scripts/ai-capability-discovery.py --json
python3 scripts/ai-capability-discovery.py --run-kport
python3 scripts/ai-capability-discovery.py --kport-json /path/to/profile.json
```

The command performs local best-effort probes only. It does not require root,
install software, load drivers/kernel modules, change firmware, benchmark
hardware, access the network, or transmit telemetry.

## State semantics

- **Visible device:** a device node or sysfs device is visible to this process;
  this does not prove permissions or driver functionality.
- **Candidate runtime:** a known runtime tool, package, or platform API is
  detected; this does not prove it can execute on a compatible accelerator.
- **Verified usable:** reserved for a future backend adapter that performs a
  bounded, non-destructive runtime capability query and records attributable
  evidence. This first increment intentionally reports no verified backends.
- **Unknown/not detected:** the probe could not establish presence; it is not
  proof that the hardware is absent.

The inventory separates native execution architecture from cross-compilation
targets. It does not infer physical-host capabilities from inside a guest.

## Runtime adapter contract

Future adapters should report backend ID/version, privacy-preserving device
identity, state, timestamp, source/probe, confidence, diagnostic reason,
verified workload/data-type/memory support, and whether the check was read-only
or required permissions. Accelerated routing must require fresh
verified-usable evidence for the target workload; otherwise use CPU/software.

Planned adapter families include CUDA, ROCm, OpenVINO, Intel NPU, Vulkan,
OpenCL, Qualcomm QNN/HTP, Android NNAPI, Apple Core ML/Metal, DirectML, and
ONNX Runtime execution providers. Availability depends on OS, device, driver
and runtime versions; no list implies universal support.

## Security and privacy

Normal inventory omits serial numbers and stable unique identifiers. Remote
fleet discovery, telemetry, driver installation, privileged host inspection,
firmware changes, benchmarking and device control are separate opt-in
capabilities and are not implemented here. Containers and VMs report only
resources visible to their current process.


## Android / AOSP product targets

The capability inventory is complemented by the [Android/AOSP target taxonomy](android-aosp-target-taxonomy.md). It distinguishes mobile, desktop, TV, IoT, Wearable, Automotive, Android Auto projection, and headless deployments, and keeps product, kernel, board, userspace, artifact, and execution-context compatibility separate. A target label alone does not imply that a board, kernel patch, runtime, or image is supported.
