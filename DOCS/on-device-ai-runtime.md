# Portable on-device AI runtime

## Status

Architecture proposal; this document does not claim that any provider is already integrated or that every target device is supported.

## Goal

Give Fork-Sync-All's provider-neutral AI layer a portable way to discover and invoke local inference capabilities across Android/AOSP, ChromiumOS, Debian, and other tested Linux-kernel-based systems. Keep platform-specific services and hardware accelerators behind optional adapters.

The target is **one capability contract with multiple providers**, not one binary or model that is assumed to run everywhere.

## Existing integration points

Before adding runtime-specific code, reuse the existing AI-agnostic agent integration proposal and Agent Skills API. Skills describe portable agent workflows; they are not themselves an inference engine. Runtime/provider selection belongs in a separate capability layer, with shared authorization, validation, audit logging, and safety policy.

Related repository references:

- `DOCS/agent-skills-api.md` — portable skill package format and provider registry.
- `config/agent-skills.yml` — skill discovery/export paths and path policy.
- PR #717 — provider-neutral agent integration layer proposal.
- PR #718 — provider-neutral capability-layer documentation proposal.

## Provider candidates

| Provider | Potential role | Constraints to verify |
|---|---|---|
| Alibaba MNN | Portable local inference for supported model formats and CPU/GPU backends | Exact model/operator support, packaging, platform-specific build and acceleration backend |
| Qualcomm QNN / AI Runtime SDK | Accelerated inference on supported Qualcomm hardware, including supported Hexagon/NPU paths | SDK distribution terms, device/firmware/driver compatibility, supported OS and architecture |
| Android AICore | Access to Google's supported on-device AI features from eligible Android apps | Public API eligibility, model/task availability, Android version and device requirements |
| Samsung AI Core | Access to Samsung AI capabilities where Samsung documents a supported third-party API | Whether an API is publicly supported for this use; do not infer access from the installed system app |
| Local Dream | Reference application and possible Android image-generation provider | Android-centric architecture, exposed interface, model requirements, upstream license and dependency/model terms |
| Other runtimes | Future CPU/GPU/NPU providers | Must implement the same capability contract and pass provider conformance tests |

These are candidates, not an assertion that all adapters are available today. QNN, MNN, Android AICore, and Samsung AI Core are different kinds of components and must not be represented as interchangeable SDKs.

## Proposed capability contract

Start with a small, versioned interface. A provider should report:

- provider ID and adapter/API version;
- operating systems and architectures supported;
- available task capabilities and supported model identifiers/formats;
- execution backends available on this host (CPU/GPU/NPU/remote, as applicable);
- required libraries, drivers, permissions, and hardware;
- model memory/storage estimates when the provider can report them;
- whether execution is local or remote;
- structured errors and cancellation support.

Initial capability identifiers may include `text.generate`, `text.embed`, `image.generate`, `image.edit`, `image.analyze`, `audio.transcribe`, and `audio.synthesize`. A provider must advertise only capabilities it can actually perform. The contract should distinguish “unsupported,” “temporarily unavailable,” “model not installed,” and “hardware/driver unavailable.”

## Platform strategy

### Android / AOSP

Use documented Android APIs for Android system services. Add a separate native/local-runtime adapter for MNN or QNN only where the relevant build, ABI, SDK and device requirements are satisfied. AICore and Samsung integration should remain independent adapters.

### ChromiumOS

Determine whether the target is a ChromeOS system service, Linux container, Android runtime, or another permitted execution environment. These have different permissions and access to accelerators. Do not assume a Linux container can invoke Android system services or use the host NPU.

### Debian and other Linux distributions

Start with a portable host-side adapter and CPU execution where supported, then add tested GPU/NPU acceleration. Package dependencies separately so proprietary or hardware-specific SDKs are not required for a generic build. Publish a tested OS/architecture matrix rather than claiming all Linux distributions are supported.

### Fallback and selection

Prefer the user's configured local provider when it supports the requested task. CPU fallback is allowed only when the model/runtime supports it and resource limits permit it. Remote inference must be a separate, explicit opt-in; never silently upload prompts, files, or generated content when local inference fails.

## Security requirements

- Treat prompts, model files, inputs and outputs as potentially sensitive.
- Local IPC/service endpoints should bind to loopback or a protected Unix socket by default, authenticate clients where applicable, and never expose unauthenticated inference over the LAN.
- Enforce request-size, time, memory and concurrency limits; support cancellation.
- Keep provider credentials and vendor SDK configuration out of logs.
- Do not execute model-supplied scripts or skill contents as part of inference.
- Clearly identify when a request leaves the device.
- Keep optional providers isolated so an unavailable vendor library cannot break unrelated providers.

## Licensing and provenance gate

Before copying, vendoring, redistributing, or adapting Local Dream code, review the exact upstream license and all relevant dependency licenses. The upstream project has used CC BY-NC 4.0; treat that as a noncommercial restriction unless the current repository license and any separate permission establish otherwise. Do not assume its code can be included in a GPL-licensed project or used commercially. Review model weights and vendor SDK terms independently. Prefer clean adapter boundaries and separately licensed implementations where compatibility is uncertain.

## Initial source-level findings

The upstream Local Dream README describes an Android Stable Diffusion application focused on SD 1.5 and SDXL. It documents QNN for NPU execution and MNN for CPU execution, with CPU/GPU support and model-package requirements described by the project. Its Android Gradle configuration currently identifies an Android application, sets a minimum SDK of 28, and filters native builds to `arm64-v8a`. These are useful constraints: the existing app is not itself a portable Linux daemon or a generic cross-platform library.

The README credits `yhirose/cpp-httplib` as an HTTP server dependency. That fact alone does **not** establish that Local Dream exposes a stable, documented, authenticated API for external clients. The server implementation, binding address, routes, lifecycle, model-loading path, and access controls must be inspected before proposing an adapter.

The upstream `LICENSE` file is Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0). Do not copy or redistribute upstream application code into Fork-Sync-All, or assume commercial use is allowed, without confirming permission. Review third-party libraries, model weights, and vendor SDK terms independently. This is a licensing gate, not legal advice.

These findings are an initial README/build/license inspection, not a complete source audit and not hardware validation. No claim is made that QNN, MNN, AICore, or Samsung AI Core has been integrated.

## Delivery plan

1. **Inventory** — inspect current AI integration code, repository proposals, Local Dream fork/upstream diffs, runtime interfaces, model loading, and any externally callable API.
2. **Feasibility report** — record license and dependency findings, supported OS/ABI/hardware combinations, and whether Local Dream exposes a stable invocation interface. A dependency such as an HTTP library alone is not evidence of a public API.
3. **Contract and fake provider** — implement or propose the smallest versioned provider contract and a deterministic test provider; test discovery, capability matching, cancellation, structured errors and policy decisions without physical hardware.
4. **First real provider** — choose a permissively licensed, testable local runtime path for a documented Linux target; add an offline conformance test suite.
5. **Optional accelerators** — add QNN and additional MNN backends only for verified target combinations.
6. **Platform services** — implement AICore and Samsung adapters only through supported public APIs; otherwise document the blocker and avoid private interfaces.
7. **Image generation** — connect Local Dream or a compatible implementation only after its interface and license are verified.
8. **Hardware validation** — test CPU/GPU/NPU execution on named devices and clearly distinguish simulated tests from hardware-confirmed results.

## Acceptance criteria

- Generic builds do not require Android, Samsung, or Qualcomm-only SDKs.
- Providers declare real capabilities and fail clearly when unavailable.
- Unit/contract tests run without a physical accelerator or network access.
- Tests cover unsupported capabilities, missing models, unavailable drivers, cancellation, resource limits, and no silent remote fallback.
- Documentation lists tested operating systems, architectures, model formats, accelerator requirements, and license caveats.
- No downstream mirror writes, repository settings/secrets changes, workflow dispatches, or merges are performed as part of this proposal.

## Upstream references

- Local Dream upstream: https://github.com/xororz/local-dream
- Local Dream fork: https://github.com/Interested-Deving-1896/local-dream
- Alibaba MNN: https://github.com/alibaba/MNN
- Qualcomm developer documentation: https://docs.qualcomm.com/
- Android on-device AI documentation: https://developer.android.com/ai
