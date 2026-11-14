# Platform consumer and artifact packaging audit

This document records a source-backed baseline for issues #945 and #946. It is an audit and integration contract, not a claim that the requested native applications or installers already exist.

## 1. LXD-Manager as an Incus Engine consumer

### Repository inventory (2026-11-04)

The default-branch Git tree of `Interested-Deving-1896/LXD-Manager` contains exactly six entries: `.gitignore`, `README.md`, `LICENSE`, and three JPEG image assets.

There are no application source directories, Gradle settings/build files, Android manifest, Kotlin/Java source, web frontend, native client, CI workflow, API client, tests, or release metadata in the inspected tree. The `.gitignore` contains standard Android Studio/Gradle ignore patterns, but ignore patterns are not evidence of an Android application or a working APK build. The README's Architecture, Usage, and CI sections are placeholders. The MIT license file is present and includes a 2025 Container-On-Android copyright notice; that notice must be retained and reviewed before any future code reuse.

### Decision

**Not currently integratable as an executable Incus management client or Android APK.** There is no implementation to adapt, build, test, or package, and no protocol/API behavior to validate. Do not register it as a working Incus Engine consumer, vendor it, or advertise Android support based on its repository name or ignore file.

The project can become a consumer after it has an actual implementation and a documented product direction. At that point:

1. Inventory source files, build system, dependencies, license provenance, and CI.
2. Identify whether it is a desktop UI, web client, Android client, or another tool.
3. Pin a supported Incus API version and implement TLS certificate validation, authentication, authorization, and API negotiation.
4. Keep Incus as the runtime/control API. LXD-Manager must remain an optional client, not a daemon or second authority.
5. Add a versioned provider-neutral Incus Engine client contract and mock API tests for success, denied authorization, invalid TLS, API mismatch, unavailable endpoint, and destructive operations.
6. For Android/AOSP, build a genuine Android application using the Android SDK/NDK only if required by its actual implementation. The app must connect to a remote or explicitly configured local Incus endpoint; it must not bundle administrator credentials or expose an Incus socket to an untrusted UI.
7. Keep FSA's existing Incus devcontainer feature, Docker-to-Incus conversion, and image/template flows as runtime infrastructure. Avoid duplicating daemon setup or image lifecycle logic.

Vouch/contributor trust is not Incus authorization. Every privileged action must be checked by Incus permissions and explicitly confirmed by the operator.

## 2. BDFS platform artifact packaging

### Existing FSA baseline

The current `.github/workflows/bdfs-package.yml` packages a BDFS workspace/export through `fsa-api/core/adapters/bdfs/export.sh`. It supports native BDFS backends such as DwarFS and Btrfs, with devcontainer/Incus/OSTree/bootc integration detection. It is not presently a cross-platform application packager and does not demonstrate that an installable FSA BDFS application binary exists.

The existing kernel build workflows produce Linux kernel package artifacts in their own supported contexts. They do not establish Android APK, macOS DMG, iOS IPA, or Windows EXE/MSI application targets.

### KDE Connect as a reference

The user-maintained KDE Connect repository's current CMake build uses Qt 6.7+, KF 6.3+, C++20, Kirigami Addons, and Qt DBus/Quick/Network/Multimedia components, with platform-specific dependencies. Its workflows and build conventions may be inspected as examples of pinned toolchains, matrix builds, testing, and release packaging. They are not a generic BDFS build system and must not be copied wholesale or treated as proof that the KDE Connect application or BDFS backends are portable to every target.

Reuse only isolated, generic workflow patterns after dependency and license review. Keep KDE Connect optional and do not modify KDE upstream repositories.

### Artifact names are targets, not current deliverables

| Requested artifact | Required implementation gate | Current status |
|---|---|---|
| `fork-sync-all-bdfs.deb` | Linux userspace application/package definition, architecture matrix, dependencies, install/upgrade/uninstall tests, BDFS backend capability checks | Not yet implemented as an application package |
| `fork-sync-all-bdfs.apk` (Android) | Actual Android app/service, SDK/NDK build, Android permissions and storage/provider integration, device/runtime tests | Not supported by current evidence |
| `fork-sync-all-bdfs.dmg` | macOS app target, filesystem/provider API strategy, code signing/notarization, install/runtime tests | Not supported by current evidence |
| `fork-sync-all-bdfs.ipa` | iOS app/provider target using supported File Provider/document APIs and App Store-compatible entitlements | Not supported by current evidence |
| `fork-sync-all-bdfs.exe` | Windows userspace executable and verified filesystem/service strategy | Not supported by current evidence |
| `fork-sync-all-bdfs.msi` | Installer, signing, upgrade/uninstall/rollback tests, verified driver/service deployment model | Not supported by current evidence |

Android APK here means an Android application package, not Alpine Linux's APK package format.

Package-format support, application build support, kernel/filesystem backend support, and runtime support are separate capabilities. A package can install successfully while a requested filesystem backend remains unavailable. Android devices cannot accept arbitrary kernel modules merely because they are included in an APK; availability depends on the device kernel, privileges, SELinux policy, and supported filesystem interfaces. iOS does not expose conventional third-party kernel modules or unrestricted FUSE; any iOS target must use supported app/provider APIs and must not claim desktop filesystem parity.

### Required artifact contract

Before any target is enabled, each artifact must have a machine-readable manifest containing:

- project and source revision, release version, build workflow/run, and reproducible build inputs;
- target OS, architecture, ABI, minimum OS version, and toolchain versions;
- package format, dependencies, and declared application capabilities;
- filesystem/backend compatibility, kernel interface requirements, and test evidence;
- SHA-256 checksum, signing identity/status, provenance/attestation, and SBOM;
- install, update, rollback, and uninstall behavior where applicable.

Signing keys and publishing credentials remain in protected CI environments. Signing and release publication require protected approvals. Missing toolchains, unavailable runners, absent signing identities, or failed runtime tests must result in an explicit unsupported/blocked status, never a green or empty-success result.

### Recommended implementation order

1. Define the artifact manifest schema and target capability matrix; add offline validation fixtures.
2. Separate the current BDFS workspace exporter from application packaging so the existing export behavior is not misrepresented.
3. Establish one Linux userspace application/package target only after the actual FSA/BDFS executable entry point and dependencies are identified; test a .deb on supported architectures.
4. Add Android, macOS, iOS, and Windows targets only after a native app/provider implementation and target-specific runtime tests exist.
5. Reuse generic KDE Connect workflow patterns only where they are demonstrably applicable and license-compatible.

## 3. Sequencing and authority

These audits do not change the project-creation priority. Complete the Fork-Sync-All project-creation feature, pass its automated tests, and verify repository creation before starting the deferred Linux Distro Build Pipeline.

FSA remains authoritative for project identity, policy, lifecycle, build orchestration, artifact provenance, and release authorization. BDFS remains responsible for filesystem/image build capabilities. Incus remains the runtime/control plane. LXD-Manager, if implemented, is an optional client. No secrets, privileged Incus credentials, or signing keys may be embedded in client applications or artifacts.
