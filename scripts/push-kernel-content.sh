#!/usr/bin/env bash
# Push kernel version metadata to all distro kernel-base repos.
#
# Each base repo gets a lightweight commit containing:
#   READY          — sentinel that activates fetch-base.sh base repo path
#   VERSION        — kernel version pin + source URL
#   config/        — placeholder for distro/arch-specific config overrides
#   patches/       — placeholder for distro/arch-specific patches
#   README.md      — documents the repo's role
#
# fetch-base.sh reads READY, then uses VERSION to fetch the correct kernel
# tarball from kernel.org. No full kernel tree is stored here.
#
# Usage:
#   ./push-kernel-content.sh [--arch amd64 arm64 ...]
#   ./push-kernel-content.sh --dry-run
set -euo pipefail

KERNEL_DIR="/workspaces/linux-kernel"
ORG="Interested-Deving-1896"
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
WORK_DIR="/tmp/kernel-meta-work"

ARCHS=(amd64 arm64 armhf riscv64 s390x armel ppc64el mips64el loong64 i686)
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
# Strip leading 'v' for tarball URL
KVER="${KERNEL_VERSION#v}"
KMAJOR="${KVER%%.*}"
TARBALL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KMAJOR}.x/linux-${KVER}.tar.xz"
COMMIT_SHA="$(git -C "$KERNEL_DIR" rev-parse HEAD)"

echo "=== Push kernel metadata to kernel-base repos ==="
echo "Kernel: $KERNEL_VERSION ($COMMIT_SHA)"
echo "Tarball: $TARBALL_URL"
echo "Archs: ${ARCHS[*]}  Dry-run: $DRY_RUN"
echo "Started: $(date -u)"
echo ""

push_meta_to_repo() {
  local repo="$1"
  local distro="$2"
  local arch="$3"
  local remote="https://x-access-token:${GH_TOKEN}@github.com/${ORG}/${repo}.git"

  if $DRY_RUN; then
    echo "  [dry-run] → $repo"
    return 0
  fi

  # Skip if already has content
  if git ls-remote "$remote" HEAD 2>/dev/null | grep -q .; then
    echo "  [skip] $repo (already populated)"
    return 0
  fi

  # Build metadata tree in a temp dir
  local tmp="$WORK_DIR/$repo"
  rm -rf "$tmp" && mkdir -p "$tmp/config" "$tmp/patches"

  # READY sentinel — presence of this file activates fetch-base.sh
  printf '%s\n' "$KERNEL_VERSION" > "$tmp/READY"

  # VERSION — machine-readable kernel pin
  cat > "$tmp/VERSION" << EOF
kernel_version=${KVER}
kernel_tag=${KERNEL_VERSION}
kernel_sha=${COMMIT_SHA}
tarball_url=${TARBALL_URL}
distro=${distro}
arch=${arch}
generated_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

  # Config placeholder
  cat > "$tmp/config/README.md" << EOF
# Config overrides for ${distro}/${arch}

Place distro/arch-specific Kconfig fragments here.
These are applied on top of the upstream kernel config by the build system.

Files:
  config.base   — distro-wide settings
  config.${arch}  — arch-specific settings
EOF

  # Patches placeholder
  cat > "$tmp/patches/README.md" << EOF
# Patches for ${distro}/${arch}

Place distro/arch-specific patches here (applied before patchset patches).
Files should be named NNN-description.patch and listed in series.
EOF

  # README
  cat > "$tmp/README.md" << EOF
# ${repo}

Kernel base metadata for **${distro}/${arch}**.

This repo pins the upstream kernel version used as the source tree for
[xanmod-unified-kernel](https://github.com/${ORG}/xanmod-unified-kernel),
[liquorix-unified-kernel](https://github.com/${ORG}/liquorix-unified-kernel),
and [liqxanmod](https://github.com/${ORG}/liqxanmod) builds.

## Kernel version

\`${KERNEL_VERSION}\` — [${TARBALL_URL}](${TARBALL_URL})

## How it works

The build system's \`fetch-base.sh\` checks for the \`READY\` file in this repo.
When present, it reads \`VERSION\` to download the correct kernel tarball from
kernel.org rather than using a hardcoded version. Distro/arch-specific config
fragments and patches in \`config/\` and \`patches/\` are applied on top.

## Updating the kernel version

Edit \`VERSION\` and \`READY\` with the new version, commit, and push.
The next build will automatically use the updated version.
EOF

  # Commit and push
  git -C "$tmp" init -q
  git -C "$tmp" config user.email "build@kernel-base"
  git -C "$tmp" config user.name "kernel-base build"
  git -C "$tmp" add -A
  git -C "$tmp" commit -q -m "init: kernel ${KERNEL_VERSION} metadata for ${distro}/${arch}"
  git -C "$tmp" branch -M main

  if git -C "$tmp" push "$remote" main --force 2>&1 | grep -v "^$" | tail -2; then
    echo "  ✓ $repo"
  else
    echo "  ✗ $repo (FAILED)"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
}

mkdir -p "$WORK_DIR"
total=0; failed=0

for arch in "${ARCHS[@]}"; do
  echo "--- $arch ---"
  for distro in debian devuan ubuntu; do
    repo="${distro}-${arch}-kernel-base"
    push_meta_to_repo "$repo" "$distro" "$arch" || failed=$((failed+1))
    total=$((total+1))
    $DRY_RUN || sleep 1
  done
  # Also push to the arch hub repo
  repo="${arch}-deb-linux-kernel-base"
  push_meta_to_repo "$repo" "multi" "$arch" || failed=$((failed+1))
  total=$((total+1))
  $DRY_RUN || sleep 1
done

rm -rf "$WORK_DIR"
echo ""
echo "=== Done: $((total-failed))/$total pushed, $failed failed. $(date -u) ==="
