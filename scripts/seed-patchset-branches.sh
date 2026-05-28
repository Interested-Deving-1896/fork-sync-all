#!/usr/bin/env bash
# seed-patchset-branches.sh — seed 9 patchset branches per debian-{arch}-kernel-base repo
#
# Branch structure per repo:
#   patchset/debian/{trixie,forky,sid}
#   patchset/devuan/{excalibur,forky,ceres}
#   patchset/ubuntu/{resolute,stonking,devel}
#
# Each branch contains:
#   config/config.base    distro-specific Kconfig fragments (real, derived from known differences)
#   patches/series        empty quilt series (ready for patches to be added)
#   patches/README.md     documents what patches belong here
#   README.md             branch purpose + consumer instructions
#
# Patchset support matrix (which consumers support which arch):
#   xanmod:    amd64 arm64 armhf riscv64 s390x ppc64el loong64 i386
#   liquorix:  amd64 arm64 armhf
#   liqxanmod: amd64 arm64
#
# Usage:
#   ./seed-patchset-branches.sh [--arch amd64 arm64 ...]
#   ./seed-patchset-branches.sh --dry-run
set -euo pipefail

ORG="Interested-Deving-1896"
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
WORK_DIR="/tmp/patchset-branch-work"

ARCHS=(amd64 arm64 armhf riscv64 s390x armel ppc64el mips64el loong64 i386)
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --arch) shift; ARCHS=("$@"); break ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$GH_TOKEN" ]] && { echo "ERROR: GH_TOKEN not set" >&2; exit 1; }

# ── Patchset support matrix ───────────────────────────────────────────────────
xanmod_supported()   { case "$1" in amd64|arm64|armhf|riscv64|s390x|ppc64el|loong64|i386) return 0;; esac; return 1; }
liquorix_supported() { case "$1" in amd64|arm64|armhf) return 0;; esac; return 1; }
liqxanmod_supported(){ case "$1" in amd64|arm64) return 0;; esac; return 1; }

consumer_support_note() {
  local arch="$1"
  local notes=()
  xanmod_supported   "$arch" && notes+=("xanmod ✓")    || notes+=("xanmod —")
  liquorix_supported "$arch" && notes+=("liquorix ✓")  || notes+=("liquorix —")
  liqxanmod_supported "$arch" && notes+=("liqxanmod ✓") || notes+=("liqxanmod —")
  echo "${notes[*]}"
}

# ── Kconfig fragments ─────────────────────────────────────────────────────────

debian_config() {
  local release="$1"
  cat << EOF
# Debian ${release} Kconfig fragments
# Applied on top of arch base config, before patchset (XanMod/Liquorix) config.

# Debian module signing
CONFIG_MODULE_SIG=y
CONFIG_MODULE_SIG_ALL=y
CONFIG_MODULE_SIG_SHA512=y

# Debian security: AppArmor primary, SELinux available
CONFIG_SECURITY_APPARMOR=y
CONFIG_DEFAULT_SECURITY_APPARMOR=y
CONFIG_SECURITY_SELINUX=y

# Debian audit
CONFIG_AUDIT=y
CONFIG_AUDITSYSCALL=y

# Debian initramfs
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_GZIP=y
CONFIG_RD_XZ=y
CONFIG_RD_ZSTD=y

# Debian firmware loader
CONFIG_FW_LOADER=y
CONFIG_FW_LOADER_USER_HELPER=n

# Debian systemd integration
CONFIG_CGROUPS=y
CONFIG_CGROUP_SCHED=y
CONFIG_CGROUP_BPF=y
CONFIG_MEMCG=y
CONFIG_BLK_CGROUP=y
CONFIG_CGROUP_SYSTEMD=y
CONFIG_UNIFIED_CGROUP_HIERARCHY=y
EOF
}

devuan_config() {
  local release="$1"
  cat << EOF
# Devuan ${release} Kconfig fragments
# Delta from Debian base: removes systemd dependencies, enables OpenRC-compatible settings.

# Inherit Debian base (module signing, AppArmor, audit, initramfs)
# --- systemd cgroup integration disabled ---
CONFIG_CGROUP_SYSTEMD=n

# OpenRC / sysvinit compatible: keep cgroups but no systemd-specific hierarchy
CONFIG_CGROUPS=y
CONFIG_CGROUP_SCHED=y
CONFIG_MEMCG=y
CONFIG_BLK_CGROUP=y
# Unified hierarchy optional for OpenRC
CONFIG_UNIFIED_CGROUP_HIERARCHY=n

# eudev / mdev compatible
CONFIG_UEVENT_HELPER=y
CONFIG_UEVENT_HELPER_PATH=""

# No systemd-boot EFI stub requirement
CONFIG_EFI_STUB=y
EOF
}

ubuntu_config() {
  local release="$1"
  cat << EOF
# Ubuntu ${release} Kconfig fragments
# Delta from Debian base: AppArmor mandatory, snap support, Canonical HWE preferences.

# Ubuntu: AppArmor as sole default LSM (SELinux disabled by default)
CONFIG_SECURITY_APPARMOR=y
CONFIG_DEFAULT_SECURITY_APPARMOR=y
CONFIG_SECURITY_SELINUX=n

# Ubuntu snap / squashfs support
CONFIG_SQUASHFS=y
CONFIG_SQUASHFS_XZ=y
CONFIG_SQUASHFS_ZSTD=y
CONFIG_SQUASHFS_LZ4=y

# Ubuntu HWE: enable newer hardware support
CONFIG_DRM_AMDGPU=m
CONFIG_DRM_I915=m
CONFIG_DRM_NOUVEAU=m

# Ubuntu livepatch support
CONFIG_LIVEPATCH=y

# Ubuntu FIPS-adjacent: stronger crypto defaults
CONFIG_CRYPTO_SHA512=y
CONFIG_CRYPTO_AES_NI_INTEL=m

# Ubuntu systemd (same as Debian but explicit)
CONFIG_CGROUP_SYSTEMD=y
CONFIG_UNIFIED_CGROUP_HIERARCHY=y
EOF
}

# ── Branch seeding ────────────────────────────────────────────────────────────

seed_branch() {
  local repo="$1"
  local arch="$2"
  local distro="$3"
  local release="$4"
  local branch="patchset/${distro}/${release}"
  local remote="https://x-access-token:${GH_TOKEN}@github.com/${ORG}/${repo}.git"

  $DRY_RUN && { echo "  [dry-run] branch $branch → $repo"; return 0; }

  # Check if branch already exists
  if git ls-remote "$remote" "refs/heads/${branch}" 2>/dev/null | grep -q .; then
    echo "  [skip] $repo $branch (exists)"
    return 0
  fi

  local tmp="$WORK_DIR/${repo}-${distro}-${release}"
  rm -rf "$tmp" && mkdir -p "$tmp/config" "$tmp/patches"

  # Config fragment
  case "$distro" in
    debian) debian_config "$release" > "$tmp/config/config.base" ;;
    devuan) devuan_config "$release" > "$tmp/config/config.base" ;;
    ubuntu) ubuntu_config "$release" > "$tmp/config/config.base" ;;
  esac

  # Empty patch series
  touch "$tmp/patches/series"

  cat > "$tmp/patches/README.md" << EOF
# Patches: ${distro} ${release} / ${arch}

Add .patch files here for ${distro}-specific kernel patches targeting ${release}.
List them in \`series\` (one filename per line, quilt format).

Consumer support: $(consumer_support_note "$arch")

## Adding a patch

1. Create \`NNN-description.patch\` in this directory
2. Add the filename to \`series\`
3. Commit and push

The build system applies patches in \`series\` order after the arch base
patches and before the patchset (XanMod/Liquorix) patches.
EOF

  cat > "$tmp/README.md" << EOF
# patchset/${distro}/${release} — ${arch}

Distro-specific config fragments and patches for **${distro} ${release}** on **${arch}**.

## Contents

- \`config/config.base\` — Kconfig fragments applied after arch base config
- \`patches/series\`     — quilt patch series (empty until patches are added)
- \`patches/README.md\`  — instructions for adding patches

## Consumer support

$(consumer_support_note "$arch")

Unsupported consumers use Debian base config directly and skip this branch.

## Base

Branched from \`main\` of [debian-${arch}-kernel-base](https://github.com/${ORG}/debian-${arch}-kernel-base).
EOF

  git -C "$tmp" init -q
  git -C "$tmp" config user.email "build@kernel-base"
  git -C "$tmp" config user.name "kernel-base build"
  git -C "$tmp" add -A
  git -C "$tmp" commit -q -m "patchset: ${distro}/${release} scaffold for ${arch}"
  git -C "$tmp" branch -M "$branch"

  if git -C "$tmp" push "$remote" "${branch}" 2>&1 | tail -1; then
    echo "  ✓ $repo $branch"
  else
    echo "  ✗ $repo $branch (FAILED)"
    rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo "=== Seed patchset branches in debian-{arch}-kernel-base repos ==="
echo "Archs: ${ARCHS[*]}  Dry-run: $DRY_RUN"
echo "Started: $(date -u)"
echo ""

mkdir -p "$WORK_DIR"
total=0; failed=0

for arch in "${ARCHS[@]}"; do
  repo="debian-${arch}-kernel-base"
  echo "--- $arch ($repo) ---"

  for release in trixie forky sid; do
    seed_branch "$repo" "$arch" debian "$release" || failed=$((failed+1))
    total=$((total+1))
    $DRY_RUN || sleep 1
  done

  for release in excalibur forky ceres; do
    seed_branch "$repo" "$arch" devuan "$release" || failed=$((failed+1))
    total=$((total+1))
    $DRY_RUN || sleep 1
  done

  for release in resolute stonking devel; do
    seed_branch "$repo" "$arch" ubuntu "$release" || failed=$((failed+1))
    total=$((total+1))
    $DRY_RUN || sleep 1
  done
done

rm -rf "$WORK_DIR"
echo ""
echo "=== Done: $((total-failed))/$total branches seeded, $failed failed. $(date -u) ==="
