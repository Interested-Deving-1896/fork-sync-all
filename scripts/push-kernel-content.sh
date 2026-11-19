#!/usr/bin/env bash
# push-kernel-content.sh — push kernel version metadata to debian-{arch}-kernel-base repos
#
# New model: 10 repos only (one per arch, Debian as authoritative base).
# Each repo gets: READY, VERSION, config/, patches/, README.md
# Devuan/Ubuntu are patchset branches within these repos, not separate repos.
# i386 is the correct Debian name for 32-bit x86 (not i686).
#
# Usage:
#   ./push-kernel-content.sh [--arch amd64 arm64 ...]
#   ./push-kernel-content.sh --dry-run
set -euo pipefail

KERNEL_DIR="/workspaces/linux-kernel"
ORG="Interested-Deving-1896"
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
WORK_DIR="/tmp/kernel-meta-work"

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
[[ ! -d "$KERNEL_DIR/.git" ]] && { echo "ERROR: Kernel not cloned at $KERNEL_DIR" >&2; exit 1; }

KERNEL_VERSION="$(git -C "$KERNEL_DIR" describe --tags 2>/dev/null || echo 'v6.9')"
KVER="${KERNEL_VERSION#v}"
KMAJOR="${KVER%%.*}"
TARBALL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KMAJOR}.x/linux-${KVER}.tar.xz"
COMMIT_SHA="$(git -C "$KERNEL_DIR" rev-parse HEAD)"

echo "=== Push kernel metadata to debian-{arch}-kernel-base repos ==="
echo "Kernel: $KERNEL_VERSION  Tarball: $TARBALL_URL"
echo "Archs: ${ARCHS[*]}  Dry-run: $DRY_RUN"
echo "Started: $(date -u)"
echo ""

push_meta() {
  local arch="$1"
  local repo="debian-${arch}-kernel-base"
  local remote="https://x-access-token:${GH_TOKEN}@github.com/${ORG}/${repo}.git"

  $DRY_RUN && { echo "  [dry-run] → $repo"; return 0; }

  if git ls-remote "$remote" HEAD 2>/dev/null | grep -q .; then
    echo "  [skip] $repo (already populated)"
    return 0
  fi

  local tmp="$WORK_DIR/$repo"
  rm -rf "$tmp" && mkdir -p "$tmp/config" "$tmp/patches"

  printf '%s\n%s\n' "$KERNEL_VERSION" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$tmp/READY"

  cat > "$tmp/VERSION" << EOF
kernel_version=${KVER}
kernel_tag=${KERNEL_VERSION}
kernel_sha=${COMMIT_SHA}
tarball_url=${TARBALL_URL}
arch=${arch}
generated_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

  cat > "$tmp/config/README.md" << EOF
# Config fragments for ${arch}

Arch-specific Kconfig fragments applied to all distros.
Distro-specific fragments live in patchset branches:
  patchset/debian/{release}/config/
  patchset/devuan/{release}/config/
  patchset/ubuntu/{release}/config/
EOF

  cat > "$tmp/patches/README.md" << EOF
# Patches for ${arch}

Arch-specific patches applied before distro or patchset patches.
List patches in \`series\` (quilt format).
EOF
  touch "$tmp/patches/series"

  cat > "$tmp/README.md" << EOF
# debian-${arch}-kernel-base

Authoritative kernel base for **${arch}** across Debian, Devuan, and Ubuntu.

Pins kernel \`${KERNEL_VERSION}\` from [kernel.org](${TARBALL_URL}).
Devuan and Ubuntu patches live as branches here — they are downstream
derivatives of Debian, not separate source trees.

## Branch structure

\`\`\`
main                          kernel version pin (this branch)
patchset/debian/trixie        Debian trixie config + patches
patchset/debian/forky         Debian forky
patchset/debian/sid           Debian sid (unstable)
patchset/devuan/excalibur     Devuan excalibur (no-systemd delta)
patchset/devuan/forky         Devuan forky
patchset/devuan/ceres         Devuan ceres (unstable)
patchset/ubuntu/resolute      Ubuntu resolute config + patches
patchset/ubuntu/stonking      Ubuntu stonking
patchset/ubuntu/devel         Ubuntu devel
\`\`\`

## Consumers

- [xanmod-unified-kernel](https://github.com/${ORG}/xanmod-unified-kernel)
- [liquorix-unified-kernel](https://github.com/${ORG}/liquorix-unified-kernel)
- [liqxanmod](https://github.com/${ORG}/liqxanmod)

## Updating the kernel version

Edit \`VERSION\` and \`READY\` on \`main\`. Consumers pick up the new version
on their next build automatically.
EOF

  git -C "$tmp" init -q
  git -C "$tmp" config user.email "build@kernel-base"
  git -C "$tmp" config user.name "kernel-base build"
  git -C "$tmp" add -A
  git -C "$tmp" commit -q -m "init: kernel ${KERNEL_VERSION} base for ${arch}"
  git -C "$tmp" branch -M main

  if git -C "$tmp" push "$remote" main --force 2>&1 | tail -1; then
    echo "  ✓ $repo"
  else
    echo "  ✗ $repo (FAILED)"
    rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"
}

mkdir -p "$WORK_DIR"
total=0; failed=0
for arch in "${ARCHS[@]}"; do
  push_meta "$arch" || failed=$((failed+1))
  total=$((total+1))
  $DRY_RUN || sleep 1
done
rm -rf "$WORK_DIR"
echo ""
echo "=== Done: $((total-failed))/$total pushed, $failed failed. $(date -u) ==="
