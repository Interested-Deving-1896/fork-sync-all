#!/usr/bin/env bash
#
# Appends a canonical ## Origins section to the README.md of every
# OSP-bound Interested-Deving-1896 repo that does not already have one.
#
# Origins content is hardcoded here — it was derived by reading each repo's
# README and structure, then cross-referencing against existing I-D-1896 forks.
# Run this once; after that, sync-upstream-sources.sh keeps the forks current.
#
# Required env vars:
#   GH_TOKEN      — PAT with repo + contents:write scope on Interested-Deving-1896
#   GITHUB_OWNER  — org to patch (default: Interested-Deving-1896)
#   DRY_RUN       — set to "true" to print patches without committing (default: false)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
GITHUB_OWNER="${GITHUB_OWNER:-Interested-Deving-1896}"
DRY_RUN="${DRY_RUN:-false}"

API="https://api.github.com"
HEADER_FILE=$(mktemp)
trap 'rm -f "$HEADER_FILE"' EXIT

info() { echo "[patch-origins] $*"; }
warn() { echo "[warn] $*" >&2; }
dry()  { echo "[dry-run] $*"; }

gh_api() {
  local method="$1" url="$2"; shift 2
  local attempt=0 max_retries=3
  while true; do
    local response http_code body
    response=$(curl -s -w "\n%{http_code}" -X "$method" \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -D "$HEADER_FILE" \
      "$@" "$url" 2>/dev/null) || true
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
    if [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
      (( attempt++ )) || true
      [[ $attempt -gt $max_retries ]] && { echo "$body"; return 1; }
      local reset now wait
      reset=$(grep -i "x-ratelimit-reset:" "$HEADER_FILE" 2>/dev/null | tr -d '\r' | awk '{print $2}')
      now=$(date +%s); wait=$(( ${reset:-0} - now + 5 ))
      [[ "$wait" -gt 0 && "$wait" -lt 3700 ]] && sleep "$wait" || sleep 60
      continue
    fi
    echo "$body"; return 0
  done
}

# Fetch README content + blob SHA for a repo. Outputs "sha|base64_content".
get_readme() {
  local repo="$1" branch="$2"
  local info
  info=$(gh_api GET "${API}/repos/${GITHUB_OWNER}/${repo}/contents/README.md?ref=${branch}") || return 1
  local sha content
  sha=$(echo "$info" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sha',''))" 2>/dev/null)
  content=$(echo "$info" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('content',''))" 2>/dev/null | tr -d '\n')
  [[ -z "$sha" || -z "$content" ]] && return 1
  echo "${sha}|${content}"
}

# Commit an updated README. $1=repo $2=branch $3=blob_sha $4=new_content_b64
commit_readme() {
  local repo="$1" branch="$2" blob_sha="$3" content_b64="$4"
  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({
  'message': 'docs: add Origins section',
  'content': sys.argv[1],
  'sha':     sys.argv[2],
  'branch':  sys.argv[3],
}))
" "$content_b64" "$blob_sha" "$branch")
  gh_api PUT "${API}/repos/${GITHUB_OWNER}/${repo}/contents/README.md" \
    -H "Content-Type: application/json" --data "$payload" > /dev/null
}

# Append an Origins block to decoded README text, then re-encode as base64.
# $1=current_decoded_text  $2=origins_block  → prints new base64
append_origins() {
  local current="$1" origins="$2"
  printf '%s\n\n%s\n' "$current" "$origins" | base64 | tr -d '\n'
}

patched=0
skipped=0
failed=0

# Push a file to a repo, creating or updating it.
# $1=repo $2=branch $3=path $4=commit_message $5=file_content (plain text)
push_file() {
  local repo="$1" branch="$2" path="$3" message="$4" content="$5"

  # Check if file already exists (to get its SHA for update)
  local existing sha=""
  existing=$(gh_api GET "${API}/repos/${GITHUB_OWNER}/${repo}/contents/${path}?ref=${branch}" 2>/dev/null) || existing=""
  sha=$(echo "$existing" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sha',''))" 2>/dev/null || true)

  local content_b64
  content_b64=$(printf '%s' "$content" | base64 | tr -d '\n')

  local payload
  payload=$(python3 -c "
import json, sys
d = {
  'message': sys.argv[1],
  'content': sys.argv[2],
  'branch':  sys.argv[3],
}
if sys.argv[4]:
    d['sha'] = sys.argv[4]
print(json.dumps(d))
" "$message" "$content_b64" "$branch" "$sha")

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Would push ${GITHUB_OWNER}/${repo}/${path}"
    return 0
  fi

  if gh_api PUT "${API}/repos/${GITHUB_OWNER}/${repo}/contents/${path}" \
      -H "Content-Type: application/json" --data "$payload" > /dev/null; then
    info "  ✓ pushed ${path}"
    return 0
  else
    warn "  ✗ failed to push ${path}"
    return 1
  fi
}

patch_repo() {
  local repo="$1" branch="$2" origins_block="$3"

  info "── ${repo} (${branch})"

  local readme_info
  readme_info=$(get_readme "$repo" "$branch") || {
    warn "  Could not fetch README for ${repo} — skipping"
    (( failed++ )) || true; return
  }

  local blob_sha current_b64 current_text
  blob_sha=$(echo "$readme_info" | cut -d'|' -f1)
  current_b64=$(echo "$readme_info" | cut -d'|' -f2-)
  current_text=$(echo "$current_b64" | base64 -d 2>/dev/null)

  if echo "$current_text" | grep -q "^## Origins"; then
    info "  Already has Origins section — skipping"
    (( skipped++ )) || true; return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Would append Origins to ${GITHUB_OWNER}/${repo}/README.md"
    dry "---"
    echo "$origins_block"
    dry "---"
    (( patched++ )) || true; return
  fi

  local new_b64
  new_b64=$(append_origins "$current_text" "$origins_block")

  if commit_readme "$repo" "$branch" "$blob_sha" "$new_b64"; then
    info "  ✓ patched"
    (( patched++ )) || true
  else
    warn "  ✗ commit failed"
    (( failed++ )) || true
  fi
}

# ── Origins blocks ────────────────────────────────────────────────────────────
# Each block is the exact markdown to append. Internal I-D-1896 repos link to
# their GitHub URL. External origins link to their canonical upstream URL.
# KDE/invent.kde.org links use https://invent.kde.org/<group>/<repo>.

patch_repo "eggs-ai" "main" \
'## Origins

eggs-ai is built on top of:
- [Interested-Deving-1896/penguins-eggs](https://github.com/Interested-Deving-1896/penguins-eggs) — the Linux remastering tool this agent wraps
- [Interested-Deving-1896/oa-tools](https://github.com/Interested-Deving-1896/oa-tools) — next-generation remastering engine (oa + coa)'

patch_repo "eggs-gui" "main" \
'## Origins

eggs-gui merges three upstream GUI projects:
- [pieroproietti/pengui](https://github.com/pieroproietti/pengui) — original PySide6 GUI for penguins-eggs
- [pieroproietti/eggsmaker](https://github.com/pieroproietti/eggsmaker) — customtkinter GUI by Jorge Luis Endres
- [jlendres/eggsmaker](https://github.com/jlendres/eggsmaker) — enhanced fork with web UI
- [charmbracelet/bubbletea](https://github.com/charmbracelet/bubbletea) — Go TUI framework (BubbleTea frontend)
- [nodegui/nodegui](https://github.com/nodegui/nodegui) — Qt6/TypeScript native desktop framework'

patch_repo "immutable-linux-framework" "main" \
'## Origins

immutable-linux-framework integrates the following immutability backends:
- [Vanilla-OS/ABRoot](https://github.com/Vanilla-OS/ABRoot) — A/B partition swap + OCI image updates
- [ashos/ashos](https://github.com/ashos/ashos) — BTRFS snapshot tree, multi-distro
- [ChimeraOS/frzr](https://github.com/ChimeraOS/frzr) — read-only BTRFS subvolume image deployment
- [blend-os/akshara](https://github.com/blend-os/akshara) — YAML-declared declarative system rebuild
- [blend-os/nearly](https://github.com/blend-os/nearly) — immutability toggle primitive (absorbed into core/mutable)
- [Interested-Deving-1896/btrfs-dwarfs-framework](https://github.com/Interested-Deving-1896/btrfs-dwarfs-framework) — BTRFS+DwarFS hybrid blend layer'

patch_repo "liquorix-unified-kernel" "main" \
'## Origins

liquorix-unified-kernel consolidates packaging for:
- [damentz/liquorix-package](https://github.com/damentz/liquorix-package) — official Liquorix kernel Debian/Ubuntu packaging
- [liquorix/liquorix-package](https://github.com/liquorix/liquorix-package) — Arch Linux packaging
- [zen-kernel/zen-kernel](https://github.com/zen-kernel/zen-kernel) — Zen patch set (the basis of Liquorix)'

patch_repo "liqxanmod" "main" \
'## Origins

liqxanmod merges two upstream kernel patch sets:
- [xanmod/linux](https://gitlab.com/xanmod/linux) — XanMod performance patch set
- [zen-kernel/zen-kernel](https://github.com/zen-kernel/zen-kernel) — Zen/Liquorix low-latency patch set
- [damentz/liquorix-package](https://github.com/damentz/liquorix-package) — Liquorix build configuration reference'

patch_repo "lkf" "main" \
'## Origins

lkf consolidates patterns from 15 upstream kernel tooling projects:
- [ghazzor/Xanmod-Kernel-Builder](https://github.com/ghazzor/Xanmod-Kernel-Builder) — Clang/LLVM CI workflow, LTO config patterns
- [kodx/symlink-initrd-kernel-in-root](https://github.com/kodx/symlink-initrd-kernel-in-root) — `/vmlinuz` + `/initrd.img` symlink management
- [rawdaGastan/go-extract-vmlinux](https://github.com/rawdaGastan/go-extract-vmlinux) — vmlinux/vmlinuz extraction logic
- [elfmaster/kdress](https://github.com/elfmaster/kdress) — vmlinuz → debuggable vmlinux with full ELF symbol table
- [eballetbo/unzboot](https://github.com/eballetbo/unzboot) — EFI zboot ARM64 kernel extraction
- [Biswa96/android-kernel-builder](https://github.com/Biswa96/android-kernel-builder) — Android cross-compile pipeline
- [AlexanderARodin/LinuxComponentsBuilder](https://github.com/AlexanderARodin/LinuxComponentsBuilder) — kernel + initrd + rootfs + squash pipeline
- [osresearch/linux-builder](https://github.com/osresearch/linux-builder) — appliance/firmware kernel, unified EFI image
- [tsirysndr/vmlinux-builder](https://github.com/tsirysndr/vmlinux-builder) — multi-arch CI, version normalization
- [rizalmart/puppy-linux-kernel-maker](https://github.com/rizalmart/puppy-linux-kernel-maker) — AUFS patch workflow, firmware driver packaging
- [deepseagirl/easylkb](https://github.com/deepseagirl/easylkb) — QEMU+GDB debug environment
- [limitcool/xm](https://github.com/limitcool/xm) — cross-compile manager concept
- [masahir0y/kbuild_skeleton](https://github.com/masahir0y/kbuild_skeleton) — Kbuild/Kconfig standalone template
- [h0tc0d3/kbuild](https://github.com/h0tc0d3/kbuild) — flexible CLI flags, DKMS integration, GPG verification
- [WangNan0/kbuild-standalone](https://github.com/WangNan0/kbuild-standalone) — standalone kconfig/kbuild as a library'

patch_repo "lkm" "main" \
'## Origins

lkm merges two complementary kernel management tools:
- [Interested-Deving-1896/lkf](https://github.com/Interested-Deving-1896/lkf) — Linux Kernel Framework (shell build pipeline)
- [Interested-Deving-1896/ukm](https://github.com/Interested-Deving-1896/ukm) — Universal Kernel Manager (runtime management)'

patch_repo "oa-tools" "main" \
'## Origins

oa-tools is the next-generation evolution of:
- [pieroproietti/penguins-eggs](https://github.com/pieroproietti/penguins-eggs) — the original Linux remastering tool this project supersedes'

patch_repo "penguins-eggs-audit" "main" \
'## Origins

penguins-eggs-audit integrates 39 git-based projects. Key upstreams by domain:

**Distribution & Decentralized**
- [git-lfs/git-lfs](https://github.com/git-lfs/git-lfs) — ISO tracking via Git LFS
- [nicowillis/giftless](https://github.com/nicowillis/giftless) — self-hosted Git LFS server
- [gogs/gogs](https://github.com/gogs/gogs) — self-hosted Git registry
- [brig-ipfs/brig](https://github.com/sahib/brig) — IPFS-based distribution via brig
- [ipfs/go-ipfs](https://github.com/ipfs/go-ipfs) — IPFS node

**Config Management & Build**
- [presslabs/gitfs](https://github.com/presslabs/gitfs) — FUSE-mounted git repo for wardrobe editing
- [system-transparency/system-transparency](https://github.com/system-transparency/system-transparency) — reproducible verified builds

**Dev Workflow & Security**
- [linear-b/gitstream](https://github.com/linear-b/gitstream) — PR automation rules
- [jfrog/frogbot](https://github.com/jfrog/frogbot) — security scanning GitHub Action
- [anchore/syft](https://github.com/anchore/syft) — SBOM generation
- [anchore/grant](https://github.com/anchore/grant) — license compliance scanning'

patch_repo "penguins-eggs-book" "main" \
'## Origins

penguins-eggs-book documents:
- [pieroproietti/penguins-eggs](https://github.com/pieroproietti/penguins-eggs) — the tool this book covers
- [hosseinseilani/penguins-eggs-book](https://github.com/hosseinseilani/penguins-eggs-book) — original book authored by Hossein Seilany'

patch_repo "penguins-incus-platform" "main" \
'## Origins

penguins-incus-platform unifies:
- [lxc/incus](https://github.com/lxc/incus) — the Incus container and VM manager this platform wraps
- [lxc/distrobuilder](https://github.com/lxc/distrobuilder) — LXC/Incus rootfs image builder (Go)
- [itoffshore/distrobuilder-menu](https://github.com/itoffshore/distrobuilder-menu) — Python TUI menu for distrobuilder
- [Interested-Deving-1896/penguins-eggs](https://github.com/Interested-Deving-1896/penguins-eggs) — penguins-eggs integration hooks'

patch_repo "penguins-kernel-manager" "main" \
'## Origins

penguins-kernel-manager is forked from and extends:
- [Interested-Deving-1896/lkm](https://github.com/Interested-Deving-1896/lkm) — Linux Kernel Manager (lkf + ukm merger)
- [Interested-Deving-1896/lkf](https://github.com/Interested-Deving-1896/lkf) — Linux Kernel Framework (shell build pipeline)
- [Interested-Deving-1896/ukm](https://github.com/Interested-Deving-1896/ukm) — Universal Kernel Manager (runtime management)
- [bkw777/mainline](https://github.com/bkw777/mainline) — Ubuntu Mainline PPA kernel installer
- [bobbycomet/XKM-Multi-Kernel-Manager](https://github.com/bobbycomet/XKM-Multi-Kernel-Manager) — multi-kernel manager reference'

patch_repo "penguins-powerwash" "main" \
'## Origins

penguins-powerwash is forked from and extends:
- [Interested-Deving-1896/linux-powerwash](https://github.com/Interested-Deving-1896/linux-powerwash) — the distro-agnostic factory reset tool this project rebrands
- [Interested-Deving-1896/penguins-eggs](https://github.com/Interested-Deving-1896/penguins-eggs) — penguins-eggs integration (pre/post-reset ISO snapshots)
- [Interested-Deving-1896/penguins-recovery](https://github.com/Interested-Deving-1896/penguins-recovery) — recovery integration (snapshot + re-layer after reset)'

patch_repo "ukm" "main" \
'## Origins

ukm combines the best of two upstream kernel managers:
- [bkw777/mainline](https://github.com/bkw777/mainline) — Ubuntu Mainline PPA kernel installer (GUI + CLI)
- [bobbycomet/XKM-Multi-Kernel-Manager](https://github.com/bobbycomet/XKM-Multi-Kernel-Manager) — multi-distro kernel manager reference'

patch_repo "xanmod-unified-kernel" "main" \
'## Origins

xanmod-unified-kernel consolidates packaging for:
- [xanmod/linux](https://gitlab.com/xanmod/linux) — XanMod kernel source (MAIN, EDGE, LTS, RT branches)
- [xanmod/linux-tkg](https://github.com/xanmod/linux-tkg) — TkG build system and patch collection reference
- [CachyOS/linux-cachyos](https://github.com/CachyOS/linux-cachyos) — CachyOS scheduler patch reference'

patch_repo "btrfs-dwarfs-framework" "master" \
'## Origins

btrfs-dwarfs-framework blends two upstream filesystem projects:
- [kdave/btrfs-devel](https://github.com/kdave/btrfs-devel) — BTRFS kernel development tree
- [mhx/dwarfs](https://github.com/mhx/dwarfs) — DwarFS high-compression read-only filesystem
- [containers/fuse-overlayfs](https://github.com/containers/fuse-overlayfs) — userspace overlay fallback when kernel module unavailable'

patch_repo "penguins-eggs" "master" \
'## Origins

penguins-eggs is the original Linux remastering tool by Piero Proietti:
- [pieroproietti/penguins-eggs](https://github.com/pieroproietti/penguins-eggs) — upstream source (this repo tracks it)
- [pieroproietti/oa-tools](https://github.com/pieroproietti/oa-tools) — next-generation successor (oa + coa architecture)'

# ── KPort — original project, push dep-graph/origins.md ─────────────────────
# invent.kde.org/neon/neon is a group URL, not a repo. The actual KDE Neon
# projects are the 6 individual repos in that group, all forked into I-D-1896
# and mirrored under neon-deving on GitLab.

KPORT_ORIGINS_MD='# KPort Origins

KPort is an original project — a Portage-inspired package repository for KDE Neon using Pacstall.
It was created from the following upstream inspirations:

| Origin | Host | Fork in I-D-1896 |
|--------|------|-----------------|
| [KDE/neon-neon-repositories](https://github.com/KDE/neon-neon-repositories) | GitHub | ✅ |
| [neon/ubuntu-core](https://invent.kde.org/neon/ubuntu-core) | KDE Invent | ✅ |
| [neon/pkg-kde-tools](https://invent.kde.org/neon/pkg-kde-tools) | KDE Invent | ✅ |
| [neon/pkg-kde-jenkins](https://invent.kde.org/neon/pkg-kde-jenkins) | KDE Invent | ✅ |
| [neon/pkg-kde-dev-scripts](https://invent.kde.org/neon/pkg-kde-dev-scripts) | KDE Invent | ✅ |
| [neon/docker-images](https://invent.kde.org/neon/docker-images) | KDE Invent | ✅ |
| [neon/qt-kde-team.pages.debian.net](https://invent.kde.org/neon/qt-kde-team.pages.debian.net) | KDE Invent | ✅ |
| [gentoo/portage](https://github.com/gentoo/portage) | GitHub | ✅ |
| [pacstall/pacstall](https://github.com/pacstall/pacstall) | GitHub | ✅ |
| [KDE/craft](https://github.com/KDE/craft) | GitHub | ✅ |
| [KDE/craft-blueprints-kde](https://github.com/KDE/craft-blueprints-kde) | GitHub | ✅ |
| [KDE/craft-blueprints-community](https://github.com/KDE/craft-blueprints-community) | GitHub | ✅ |
| [KDE/kde-builder](https://github.com/KDE/kde-builder) | GitHub | ✅ |
| [KDE/kdesrc-build](https://github.com/KDE/kdesrc-build) | GitHub | ✅ |
| [KDE/kde-build-metadata](https://github.com/KDE/kde-build-metadata) | GitHub | ✅ |
| [KDE/kdevplatform](https://github.com/KDE/kdevplatform) | GitHub | ✅ |
| [KDE/superbuild](https://github.com/KDE/superbuild) | GitHub | ✅ |
| [KDE/android-builder](https://github.com/KDE/android-builder) | GitHub | ✅ |
'

info "── kport (main) — push dep-graph/origins.md"
if push_file "kport" "main" "dep-graph/origins.md" \
    "chore: update dep-graph/origins.md (replace neon/neon group URL with individual repos)" \
    "$KPORT_ORIGINS_MD"; then
  (( patched++ )) || true
else
  (( failed++ )) || true
fi

# ── KDE Neon upstream repos — push dep-graph/origins.md ──────────────────────
# These are the 6 projects in invent.kde.org/neon, forked into I-D-1896 and
# mirrored under neon-deving on GitLab. Each is an upstream-only mirror with
# no I-D-1896 modifications — origins point back to KDE Invent.

push_file "ubuntu-core" "master" "dep-graph/origins.md" \
    "chore: add dep-graph/origins.md" \
'# ubuntu-core Origins

Mirror of [neon/ubuntu-core](https://invent.kde.org/neon/ubuntu-core) — KDE Neon Ubuntu Core snap/ISO build scripts.

| Origin | Host | Fork in I-D-1896 |
|--------|------|-----------------|
| [neon/ubuntu-core](https://invent.kde.org/neon/ubuntu-core) | KDE Invent | ✅ |
' && (( patched++ )) || (( failed++ )) || true

push_file "pkg-kde-tools" "Neon/unstable" "dep-graph/origins.md" \
    "chore: add dep-graph/origins.md" \
'# pkg-kde-tools Origins

Mirror of [neon/pkg-kde-tools](https://invent.kde.org/neon/pkg-kde-tools) — Debian packaging helpers for KDE (dh_* tools, CMake, Perl libs).

| Origin | Host | Fork in I-D-1896 |
|--------|------|-----------------|
| [neon/pkg-kde-tools](https://invent.kde.org/neon/pkg-kde-tools) | KDE Invent | ✅ |
' && (( patched++ )) || (( failed++ )) || true

push_file "pkg-kde-jenkins" "master" "dep-graph/origins.md" \
    "chore: add dep-graph/origins.md" \
'# pkg-kde-jenkins Origins

Mirror of [neon/pkg-kde-jenkins](https://invent.kde.org/neon/pkg-kde-jenkins) — Jenkins CI job definitions for KDE Neon packaging.

| Origin | Host | Fork in I-D-1896 |
|--------|------|-----------------|
| [neon/pkg-kde-jenkins](https://invent.kde.org/neon/pkg-kde-jenkins) | KDE Invent | ✅ |
' && (( patched++ )) || (( failed++ )) || true

push_file "pkg-kde-dev-scripts" "master" "dep-graph/origins.md" \
    "chore: add dep-graph/origins.md" \
'# pkg-kde-dev-scripts Origins

Mirror of [neon/pkg-kde-dev-scripts](https://invent.kde.org/neon/pkg-kde-dev-scripts) — dev scripts for building and snarfing KDE source packages.

| Origin | Host | Fork in I-D-1896 |
|--------|------|-----------------|
| [neon/pkg-kde-dev-scripts](https://invent.kde.org/neon/pkg-kde-dev-scripts) | KDE Invent | ✅ |
' && (( patched++ )) || (( failed++ )) || true

push_file "docker-images" "Neon/unstable" "dep-graph/origins.md" \
    "chore: add dep-graph/origins.md" \
'# docker-images Origins

Mirror of [neon/docker-images](https://invent.kde.org/neon/docker-images) — Docker build environment for KDE Neon.

| Origin | Host | Fork in I-D-1896 |
|--------|------|-----------------|
| [neon/docker-images](https://invent.kde.org/neon/docker-images) | KDE Invent | ✅ |
' && (( patched++ )) || (( failed++ )) || true

push_file "qt-kde-team.pages.debian.net" "master" "dep-graph/origins.md" \
    "chore: add dep-graph/origins.md" \
'# qt-kde-team.pages.debian.net Origins

Mirror of [neon/qt-kde-team.pages.debian.net](https://invent.kde.org/neon/qt-kde-team.pages.debian.net) — KDE dependency graph website (includes kde.dot, a Graphviz dep graph of all KDE modules).

| Origin | Host | Fork in I-D-1896 |
|--------|------|-----------------|
| [neon/qt-kde-team.pages.debian.net](https://invent.kde.org/neon/qt-kde-team.pages.debian.net) | KDE Invent | ✅ |
' && (( patched++ )) || (( failed++ )) || true

# ── penguins-recovery ─────────────────────────────────────────────────────────

patch_repo "penguins-recovery" "main" \
'## Origins

penguins-recovery provides recovery tooling for the penguins ecosystem:
- [Interested-Deving-1896/penguins-eggs](https://github.com/Interested-Deving-1896/penguins-eggs) — penguins-eggs integration (snapshot source for recovery images)
- [Interested-Deving-1896/penguins-powerwash](https://github.com/Interested-Deving-1896/penguins-powerwash) — powerwash integration (recovery triggered post-reset)'

# ── Incus / virtualisation repos ─────────────────────────────────────────────

push_file "Incus-MacOS-Toolkit" "main" "dep-graph/origins.md" \
    "chore: add dep-graph/origins.md" \
'# Incus-MacOS-Toolkit Origins

Original project — unified toolkit for macOS KVM virtualisation and Linux filesystem access on macOS via Incus.

| Origin | Host | Fork in I-D-1896 |
|--------|------|-----------------|
| [lxc/incus](https://github.com/lxc/incus) | GitHub | ✅ |
' && (( patched++ )) || (( failed++ )) || true

push_file "incus-image-server" "main" "dep-graph/origins.md" \
    "chore: add dep-graph/origins.md" \
'# incus-image-server Origins

Original project — unified simplestreams image server for LXC/LXD/Incus with multi-distro build pipeline.

| Origin | Host | Fork in I-D-1896 |
|--------|------|-----------------|
| [lxc/incus](https://github.com/lxc/incus) | GitHub | ✅ |
| [lxc/distrobuilder](https://github.com/lxc/distrobuilder) | GitHub | ✅ |
' && (( patched++ )) || (( failed++ )) || true

push_file "incus-windows-toolkit" "main" "dep-graph/origins.md" \
    "chore: add dep-graph/origins.md" \
'# incus-windows-toolkit Origins

Original project — toolkit for running and managing Windows VMs on Incus (QEMU/KVM) with Btrfs storage.

| Origin | Host | Fork in I-D-1896 |
|--------|------|-----------------|
| [lxc/incus](https://github.com/lxc/incus) | GitHub | ✅ |
' && (( patched++ )) || (( failed++ )) || true

push_file "incusbox" "main" "dep-graph/origins.md" \
    "chore: add dep-graph/origins.md" \
'# incusbox Origins

Original project — Incus-backed distrobox replacement using any Linux distro in the terminal via Incus containers.

| Origin | Host | Fork in I-D-1896 |
|--------|------|-----------------|
| [lxc/incus](https://github.com/lxc/incus) | GitHub | ✅ |
| [89luca89/distrobox](https://github.com/89luca89/distrobox) | GitHub | ✅ |
' && (( patched++ )) || (( failed++ )) || true

push_file "kapsule-incus-manager" "main" "dep-graph/origins.md" \
    "chore: add dep-graph/origins.md" \
'# kapsule-incus-manager Origins

Original project — unified Incus container and VM management with Qt6/QML desktop UI, web UI, and CLI.

| Origin | Host | Fork in I-D-1896 |
|--------|------|-----------------|
| [lxc/incus](https://github.com/lxc/incus) | GitHub | ✅ |
' && (( patched++ )) || (( failed++ )) || true

push_file "talos" "main" "dep-graph/origins.md" \
    "chore: add dep-graph/origins.md" \
'# talos Origins

Fork of [siderolabs/talos](https://github.com/siderolabs/talos) — Talos Linux, a modern immutable Linux distribution built for Kubernetes.

| Origin | Host | Fork in I-D-1896 |
|--------|------|-----------------|
| [siderolabs/talos](https://github.com/siderolabs/talos) | GitHub | ✅ |
' && (( patched++ )) || (( failed++ )) || true

push_file "talos-incus" "main" "dep-graph/origins.md" \
    "chore: add dep-graph/origins.md" \
'# talos-incus Origins

Fork of [windsorcli/talos-incus](https://github.com/windsorcli/talos-incus) — Talos Linux releases packaged for Incus.

| Origin | Host | Fork in I-D-1896 |
|--------|------|-----------------|
| [windsorcli/talos-incus](https://github.com/windsorcli/talos-incus) | GitHub | ✅ |
| [siderolabs/talos](https://github.com/siderolabs/talos) | GitHub | ✅ |
' && (( patched++ )) || (( failed++ )) || true

push_file "waydroid-toolkit" "main" "dep-graph/origins.md" \
    "chore: add dep-graph/origins.md" \
'# waydroid-toolkit Origins

Original project — unified management suite for Waydroid (Android in a Linux container).

| Origin | Host | Fork in I-D-1896 |
|--------|------|-----------------|
| [waydroid/waydroid](https://github.com/waydroid/waydroid) | GitHub | ✅ |
' && (( patched++ )) || (( failed++ )) || true

# ── Infrastructure / tooling repos ───────────────────────────────────────────

push_file "gitlab-enhanced" "main" "dep-graph/origins.md" \
    "chore: add dep-graph/origins.md" \
'# gitlab-enhanced Origins

Imported from the OpenOS-Project GitLab — enhanced GitLab tooling for the OSP infrastructure.

| Origin | Host | Fork in I-D-1896 |
|--------|------|-----------------|
| [openos-project/git-management_deving/gitlab-enhanced](https://gitlab.com/openos-project/git-management_deving/gitlab-enhanced) | GitLab | ✅ |
' && (( patched++ )) || (( failed++ )) || true

push_file "linux-powerwash" "main" "dep-graph/origins.md" \
    "chore: add dep-graph/origins.md" \
'# linux-powerwash Origins

Original project — distro-agnostic, filesystem-agnostic factory reset tool for Linux.
' && (( patched++ )) || (( failed++ )) || true

push_file "penguins-immutable-framework" "main" "dep-graph/origins.md" \
    "chore: add dep-graph/origins.md" \
'# penguins-immutable-framework Origins

Forked and rebranded from the penguins ecosystem immutability work.

| Origin | Host | Fork in I-D-1896 |
|--------|------|-----------------|
| [Interested-Deving-1896/immutable-linux-framework](https://github.com/Interested-Deving-1896/immutable-linux-framework) | GitHub | ✅ |
| [Interested-Deving-1896/penguins-eggs](https://github.com/Interested-Deving-1896/penguins-eggs) | GitHub | ✅ |
' && (( patched++ )) || (( failed++ )) || true

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  patch-origins-sections complete"
echo "  Patched : ${patched}"
echo "  Skipped : ${skipped}"
echo "  Failed  : ${failed}"
echo "════════════════════════════════════════"

[[ "$failed" -gt 0 ]] && exit 1
exit 0
