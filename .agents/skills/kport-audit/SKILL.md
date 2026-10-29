---
name: kport-audit
description: >
  Audit and fix KPort pacscripts for completeness, correctness, and consistency.
  Use when asked to audit KPort, fix pacscript fields, fill sha256sums, bump
  versions, fill depends=(), fix GPU/CPU tiers, or clean up URLs.
  Triggers on "audit KPort", "fix pacscripts", "fill sha256", "bump version",
  "fill depends", "kport audit", "pacscript audit".
---

# KPort Audit Skill

## Overview

KPort pacscripts live under `packages/` (production) and `overlays/`
(arch-specific or community packages). Each pacscript is a bash file with
standard Pacstall fields plus KPort-specific fields (`KNEON_CHANNEL`,
`KGPU_MIN`, `KCPU_MIN`, `KUSE`, `KSLOT`).

The audit workflow runs in rounds. Each round scans for a class of issues,
fixes them, commits, and opens a PR. Merge each PR before starting the next.

---

## Audit Checklist

Run these checks in order. All use `find packages/ overlays/ -name "*.pacscript"`.

### 1. SKIP / placeholder sha256sums
```bash
# Remaining SKIP placeholders
find packages/ overlays/ -name "*.pacscript" | xargs grep -l '"SKIP"'

# Fake hashes (repeating byte pattern)
find packages/ overlays/ -name "*.pacscript" | \
  xargs grep -rn '"[a-f0-9]\{64\}"' | \
  awk -F'"' '{print $2}' | sort | uniq -d
```
Fix with `scripts/kport/fill-sha256.sh --dir <dir>`. The script expands
`${pkgver}`/`${pkgname}` in URLs before fetching. For overlays, patch manually:
```bash
curl -sL "<url>" | sha256sum
# then edit the pacscript directly
```

### 2. Missing required KPort fields
```bash
find packages/ overlays/ -name "*.pacscript" | xargs grep -L 'KNEON_CHANNEL'
find packages/ overlays/ -name "*.pacscript" | xargs grep -L 'KGPU_MIN'
find packages/ overlays/ -name "*.pacscript" | xargs grep -L 'KCPU_MIN'
find packages/ overlays/ -name "*.pacscript" | xargs grep -L 'KUSE'
```
**Intentional omissions:**
- `KCPU_MIN`: pure data/icon/doc packages (`kf6-*-icon-theme`, `qt6-doc`,
  `qt6-translations`, `kdeedu-data`)
- `KUSE`: pure data/build-tools with no test suite (`lxqt-build-tools`,
  `lxqt-menu-data`, `lxqt-themes`)

Standard values:
- `KNEON_CHANNEL`: `"stable"` | `"unstable"` | `"nightly"`
- `KGPU_MIN`: `"gpu-none"` | `"gpu-sw"` | `"gpu-gl2"` | `"gpu-vk12"`
- `KCPU_MIN`: `"x86-64-v1"` | `"x86-64-v2"` | `"x86-64-v3"` | `"aarch64-baseline"` | `"i686-baseline"`
- `KUSE`: array of USE flags, e.g. `("-test")` to disable tests

### 3. Stub depends=()
```bash
find packages/ overlays/ -name "*.pacscript" | \
  xargs grep -l 'Populate after a test build\|No named runtime deps'
```
Fill from the KDE Neon apt index:
```bash
# Download once — jammy index covers most KF6/Plasma/Gear packages
curl -sL "https://archive.neon.kde.org/user/dists/jammy/main/binary-amd64/Packages.gz" \
  | gunzip > /tmp/neon-packages.txt

# Noble index for newer packages (libpyside6, qt6-interfaceframework, etc.)
curl -sL "https://archive.neon.kde.org/unstable/dists/noble/main/binary-amd64/Packages.gz" \
  | gunzip > /tmp/neon-noble-packages.txt
```
Look up each package by its KPort `pkgname` — Neon uses the same names for
most packages. Known renames:

| KPort name | Neon package name |
|---|---|
| `kf6-kactivities` | `plasma-activities` |
| `kf6-kactivities-stats` | `plasma-activities-stats` |
| `kf6-kwayland` | `kwayland` |
| `kf6-plasma-framework` | `libplasma6` |

Filter out pure system libs (`libc6`, `libstdc++6`, `libgcc-s1`, `zlib1g`).
Keep named system libs and all KPort-managed packages.

**Malformed block patterns to watch for:**

1. `).` + stub comment + bare `)` — real deps were filled but stub comment
   left as a dangling tail. Fix with:
   ```python
   re.sub(r'\)\.\n(?:  #[^\n]*\n)+\)', ')', content)
   ```

2. Unclosed `depends=(` with comment but no closing `)` — the blank line
   before `makedepends=(` acts as implicit end. Fix:
   ```python
   re.sub(r'^(depends=\()\n(?:  #[^\n]*\n)+\n', make_block(deps) + '\n\n', content, flags=re.M)
   ```

Pure data/header packages with no runtime deps: use `depends=()` (empty,
closed). Examples: `kdeedu-data`, `plasma-wayland-protocols`, `libastro1`.

### 4. Version drift
```bash
# Check version spread per category
find packages/plasma/ -name "*.pacscript" | xargs grep 'pkgver=' | \
  awk -F'"' '{print $2}' | sort -Vu

find packages/frameworks/ -name "*.pacscript" | xargs grep 'pkgver=' | \
  awk -F'"' '{print $2}' | sort -Vu

find packages/qt6/ -name "*.pacscript" | xargs grep 'pkgver=' | \
  awk -F'"' '{print $2}' | sort -Vu
```
Packages within the same upstream release train should share a version.
Outliers with independent versioning (intentional):
- `libpolkit-qt6-1-1` (0.201.x), `kf6-kirigami-addons` (1.x),
  `kf6-ktextaddons` (2.x), `qt6-phonon` (4.x), `qtcreator` (19.x),
  `plasma-wayland-protocols` (1.x), `kf6-oxygen-icon-theme` (6.1.0 is latest)

Verify tarballs exist before bumping:
```bash
curl -sI "https://download.kde.org/stable/plasma/<ver>/<name>-<ver>.tar.xz" | head -3
```
KDE download URL patterns:
- Plasma: `https://download.kde.org/stable/plasma/<ver>/<name>-<ver>.tar.xz`
- Frameworks: `https://download.kde.org/stable/frameworks/<maj.min>/<name>-<ver>.tar.xz`
- Gear: `https://download.kde.org/stable/release-service/<ver>/src/<name>-<ver>.tar.xz`
- Qt6 (GitHub): `https://github.com/qt/<repo>/archive/refs/tags/v<ver>.tar.gz`

Check available versions:
```bash
curl -sL "https://download.kde.org/stable/plasma/" | grep -oP '(?<=href=")[0-9.]+(?=/)' | sort -V | tail -5
curl -sL "https://download.kde.org/stable/frameworks/" | grep -oP '(?<=href=")[0-9.]+(?=/)' | sort -V | tail -5
```

### 5. GPU/CPU tier consistency
```bash
# Vulkan packages should use x86-64-v2 minimum, not v1
find packages/ -name "*.pacscript" | \
  xargs grep -l 'KGPU_MIN="gpu-vk' | \
  xargs grep -l 'KCPU_MIN="x86-64-v1"'
```
Vulkan 1.2 hardware requires SSE4.2-era CPUs → `x86-64-v2`.

### 6. URL cleanup
```bash
find packages/ overlays/ -name "*.pacscript" | xargs grep -rl 'url="http://' | \
  xargs sed -i 's|url="http://|url="https://|g'
```

### 7. dep-map.yml coverage
```bash
find packages/ overlays/ -name "*.pacscript" | \
  xargs grep -rh '"~apt:[^"]*"' | \
  sed 's/.*"~apt:\([^"]*\)".*/\1/' | sort -u | while read dep; do
    grep -q "^  $dep:" config/dep-map.yml || echo "UNMAPPED: $dep"
  done
```
Three KDE Gear libs resolve to KPort packages (not `~apt:`):
- `libdolphinvcs6` → `dolphin`
- `libksanecore` → `libksane`
- `okular-backends` → `okular`

### 8. masks.yml — Vulkan packages
Packages with `KGPU_MIN="gpu-vk12"` should have explicit entries in
`config/masks.yml`:
```yaml
- pkg: qt6/qt6-shadertools
  gpu: [gpu-sw, gpu-gl2]
  reason: "Requires Vulkan 1.2 (KGPU_MIN=gpu-vk12)"
```

---

## Overlay notes

### community-32bit (LXQt 1.4 for i686)
- Qt 6 / KF6 require 64-bit; this overlay uses Qt5/LXQt
- `lxqt-themes` is at 1.3.0 — upstream jumped from 1.3.0 to 2.0.0; no 1.4.0 exists
- `lxqt-build-tools`, `lxqt-menu-data`, `lxqt-themes` intentionally omit `KUSE`/`KCPU_MIN`

### community-32bit-plasma5 (KDE Plasma 5.27 LTS for i686)
- Validated against Arch Linux 32 (Plasma 5.27.7 builds on i686)
- Plasma 5.27 is the last Qt5/KF5 release; Plasma 6 requires 64-bit

---

## kport-detect-npu.sh arch dispatch

The NPU detector uses `case "$ARCH" in` to gate detectors by arch:
- `i686`: NVIDIA Tensor + OpenCL only (Intel NPU / AMD XDNA are x86-64-only)
- `x86_64`: Intel NPU → AMD XDNA → NVIDIA Tensor → OpenCL
- `aarch64`: Qualcomm HTP → ARM NPU → OpenCL
- `riscv64`: OpenCL only
- `*`: full chain as fallback

---

## Commit conventions

```
fix: audit round N — <short summary>

- <category>: <what changed>

Co-authored-by: Ona <no-reply@ona.com>
```

Branch naming: `fix/audit-round<N>`

---

## Anti-patterns

- Do NOT bump `kf6-oxygen-icon-theme` past 6.1.0 — 6.1.0 is the upstream ceiling
- Do NOT add `KCPU_MIN` to pure data packages — intentionally absent
- Do NOT treat duplicate sha256sums as suspicious — `kwin`/`kwin-wayland` share
  a tarball; the example overlay mirrors main tree intentionally
- Do NOT run `fill-sha256.sh` on `packages/` without `--dir packages/` — it
  defaults to `generated/`
- Do NOT use `6.26.0` as a Plasma version — latest Plasma is 6.6.x; `6.26.0`
  is a KF6 frameworks version
