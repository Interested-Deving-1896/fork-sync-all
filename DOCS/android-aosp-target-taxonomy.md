# Android / AOSP target taxonomy and compatibility policy

## Purpose

AOSP is a platform family, not one interchangeable device target. Fork-Sync-All
must model product/device classes independently while sharing common Android
platform, kernel, toolchain, and artifact metadata.

This document defines the first target taxonomy for the capability-discovery
and cross-project target-planning work. It is a planning/validation contract;
registering a target does not claim that a particular board, kernel, runtime,
package, or image is already supported.

## Target profiles

| Profile ID | Primary use | Important constraints | Typical validation |
|---|---|---|---|
| `android-mobile` | Phones and handheld devices | Battery/thermal limits, cellular/modem integration, camera, sensors, suspend/resume, secure boot, vendor HALs | AOSP build, boot, CTS/VTS, radio/camera/sensor tests on supported hardware |
| `android-desktop` | PCs, laptops, convertibles and workstations | Display/GPU, multi-window, keyboard/mouse/touch, docking, audio, Wi-Fi/Ethernet, suspend/resume, external displays, power/thermal policy | Desktop UI and input tests, graphics/display tests, suspend/resume, CTS/VTS, device-specific tests |
| `android-tv` | TV and streaming devices | 10-foot UI, remote/gamepad input, media codecs, DRM, HDMI/CEC, audio/video pipeline, long-lived appliance operation | TV UI/input, media playback/DRM, HDMI/CEC and CTS/VTS on target hardware |
| `android-iot` | Purpose-built embedded/IoT devices | Small resource budgets, long lifecycle, peripheral buses, connectivity, update/recovery strategy, attack surface and physical access | Board bring-up, peripheral/connectivity tests, OTA/recovery, security and power tests |
| `android-wear` | Watches and wearable devices | Very tight power/thermal/memory budgets, sensors, health-related peripheral interfaces, small displays, Bluetooth and always-on behavior | Wearable UI, sensor, connectivity, battery, suspend/resume and platform conformance tests |
| `android-automotive` | Android Automotive OS (AAOS) built into vehicles | Vehicle HALs, multiple displays/zones, safety separation, ignition/power states, CAN/Ethernet integration, audio routing, camera and vehicle lifecycle | AAOS/VTS/CTS plus vehicle-HAL, power-state, multi-user/display and hardware-in-loop tests |
| `android-auto-projection` | Phone-projected Android Auto experience | Phone remains the Android host; vehicle head unit is a projection endpoint, not an AAOS device image | Projection interoperability and phone/head-unit compatibility tests |
| `android-headless` | Headless appliance, gateway or server-like Android deployment | No assumption of desktop UI; service lifecycle, networking, storage, watchdog, remote management and security | Service boot/recovery, networking, storage, update and endurance tests |

### Important distinctions

- Android Automotive OS (AAOS) is an Android-based vehicle operating system.
  Android Auto is a phone-projection product. They are separate build and
  validation targets and must not share a target ID.
- Android TV / Google TV is not interchangeable with a generic desktop profile.
- Wear OS is the wearable product family; a generic AOSP wearable port must be
  marked as a separate product implementation until Wear OS compatibility is
  demonstrated.
- IoT is a broad deployment category, not a blanket promise that every AOSP
  release supports every microcontroller or embedded board. Record the exact
  board, SoC, Android branch, vendor BSP and supported peripherals.
- Desktop is a real first-class target. It does not imply that every Android
  phone kernel or vendor image can be reused on PC hardware.

## Layered target model

Resolve a build as a tuple rather than a single platform label:

1. **Platform/product:** AOSP branch, product makefile, product family and
   framework/API level.
2. **Kernel:** exact kernel source family/branch, architecture, defconfig,
   modules, boot image format, GKI/KMI constraints and vendor interface.
3. **Board/device:** SoC, board revision, firmware, boot chain, device tree,
   vendor modules and hardware abstraction implementations.
4. **Userspace/runtime:** ABI, Bionic/API level, HALs, graphics/media stack,
   runtime APIs and optional application environment.
5. **Artifact/package:** boot/vendor_boot/dtbo/vendor_dlkm/system_dlkm,
   system/vendor/product images, OTA payload, recovery image, container or
   host-side bundle as applicable.
6. **Execution context:** physical device, emulator, VM, container, cross-build
   host or remote builder. Host capabilities must not be attributed to target.

A target planner must preserve these layers and return explicit
supported/experimental/unsupported/unknown status for each requested
combination.

## Kernel patch and profile policy

Desktop and server patch sets from Liqxanmod, Liquorix Unified Kernel and
XanMod Unified Kernel are **candidate sources**, not Android-ready patch
bundles.

- Do not apply a whole Linux desktop or server profile to an Android kernel.
- Evaluate patches individually against the exact Android Common Kernel (ACK),
  GKI or vendor/device kernel branch and its source revision.
- Keep Android common/core changes separate from vendor/device modules. For
  Google/ChromiumOS Android Desktop work, core and vendor kernel branches have
  separate ownership and acceptance criteria; preserve that split in metadata.
- Desktop-oriented candidates may include scheduling/latency, graphics/display,
  input, audio, networking, storage, suspend/resume and power-management
  improvements. Each still needs source/API/config/KMI and regression review.
- Server/headless candidates may include networking, storage, filesystem,
  observability and throughput changes. They are relevant only to an explicit
  headless/server/appliance profile, not automatically to phones, TVs, watches
  or vehicles.
- Mobile, TV, Wearable and Automotive profiles need their own subsystem and
  power/peripheral constraints. A patch accepted for desktop is not implicitly
  accepted for those profiles.
- Prefer upstream Linux or Android Common Kernel changes where appropriate.
  Vendor-only changes remain tied to their vendor branch and device support
  declaration.

Each patch candidate should carry at least: stable patch ID, origin repository,
source commit and license, exact source-version range, target profile IDs,
architecture, dependencies/conflicts, Kconfig/config requirements, apply
strategy, touched subsystems, ABI/KMI impact, security impact, provenance,
applicability result and test evidence. Unknown or missing evidence must fail
closed.

## BDFS and KPort responsibilities

**BDFS** is the host-side build, filesystem, snapshot, staging and artifact
orchestration layer. It may prepare reproducible workspaces, capture build
provenance, validate and stage Android images, and package supported outputs.
Do not assume BDFS's Btrfs/DwarFS filesystem components can run inside an
Android device kernel or image; target-side filesystem support must be proven
independently.

**KPort** owns package/source-build and userspace integration adapters. KDE
Neon is a Linux distribution target, not an Android package repository.
KDE/Qt applications for Android require an Android-native build/package path
and compatible Android SDK/NDK, Qt/KF ports, ABI and platform APIs. A Debian
package must not be relabelled as an Android APK or system image component.
KPort should consume the shared CPU/GPU/NPU evidence contract but must not
duplicate or overstate hardware verification.

## Capability and compatibility states

Keep these states distinct:

- `detected`: hardware or device node is visible.
- `candidate`: a tool, runtime, driver or API appears to be installed.
- `verified-usable`: a bounded adapter has demonstrated the specific
  workload/API on the specific device and records fresh attributable evidence.
- `build-compatible`: source, toolchain, ABI, config and target constraints
  are satisfied for a build.
- `tested-on-target`: the resulting artifact has passed the declared target
  test matrix on identified hardware/emulator.
- `unsupported` / `unknown`: explicit negative or insufficient evidence.

A candidate runtime does not prove acceleration. A successful cross-compile
does not prove bootability. An emulator test does not replace real hardware,
vehicle, radio, media, sensor or power-state testing.

## Minimum validation gates

1. Schema and profile-ID validation; reject unknown profile IDs.
2. Exact source/branch/board/toolchain compatibility checks.
3. Patch dry-run/applicability and conflict checks against the pinned kernel.
4. Kernel config and ABI/KMI checks where relevant.
5. Reproducible build and artifact manifest/provenance checks.
6. Emulator/QEMU smoke tests where meaningful.
7. Real-device tests for hardware-specific paths; use dedicated hardware
   runners and never infer results from hosted software-only runners.
8. Product-specific conformance and subsystem tests (CTS/VTS, media, vehicle
   HAL, sensor, peripheral, OTA/recovery, suspend/resume, etc.).
9. Explicit release gate and human review for vendor/device or safety-critical
   changes.

## Rollout order

1. Land the shared taxonomy and validators in Fork-Sync-All.
2. Add read-only target metadata adapters to KPort, BDFS and the three kernel
   projects; do not fork their build engines.
3. Start with Android Desktop Core and Vendor as distinct integration tracks,
   alongside a generic AOSP mobile baseline.
4. Add TV, Wearable, Automotive, IoT and headless profiles as separate
   validation tracks with named hardware/product owners.
5. Only promote a profile or patch from candidate to supported after the
   relevant source, build, device and conformance evidence is attached.

## Non-goals

This taxonomy does not claim that all Android branches support all device
classes, that every kernel patch is portable, that generic IoT hardware is
covered, or that one CI emulator can validate physical devices. It does not
authorize privileged device changes, firmware flashing, driver installation
or publication of unverified images.
