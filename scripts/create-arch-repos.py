#!/usr/bin/env python3
"""
create-arch-repos.py

Creates the full Debian-family kernel + CD repo set for a given architecture,
mirroring the i386 pattern exactly. Handles GitHub API rate limits automatically.

Usage:
    python3 create-arch-repos.py --arch amd64
    python3 create-arch-repos.py --arch arm64
    python3 create-arch-repos.py --arch amd64 arm64   # multiple at once
    python3 create-arch-repos.py --dry-run --arch amd64

Repo structure created per architecture (35 repos):
  Individual (21):
    debian-linux-{arch}-{release}     × 3 releases
    debian-cd-{arch}-{release}        × 3 releases
    debian-{release}-{arch}           × 3 releases  (monorepo)
    devuan-linux-{arch}-{release}     × 3 releases
    devuan-cd-{arch}-{release}        × 3 releases
    devuan-{release}-{arch}           × 3 releases  (monorepo)
    ubuntu-linux-{arch}-{release}     × 3 releases
    ubuntu-cd-{arch}-{release}        × 3 releases
    ubuntu-{release}-{arch}           × 3 releases  (monorepo)

  Family bundles (9):
    debian-linux-{arch}-trixie-forky-sid
    debian-cd-{arch}-trixie-forky-sid
    debian-{arch}-trixie-forky-sid
    devuan-linux-{arch}-excalibur-forky-ceres
    devuan-cd-{arch}-excalibur-forky-ceres
    devuan-{arch}-excalibur-forky-ceres
    ubuntu-linux-{arch}-resolute-stonking-devel
    ubuntu-cd-{arch}-resolute-stonking-devel
    ubuntu-{arch}-resolute-stonking-devel

  Hub repos (5):
    {arch}-deb-family
    debian-{arch}-kernel-base
    devuan-{arch}-kernel-base
    ubuntu-{arch}-kernel-base
    {arch}-deb-linux-kernel-base
"""

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Optional

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

ORG = "Interested-Deving-1896"
TOKEN = os.environ.get("GITHUB_TOKEN", "")

DEBIAN_RELEASES = ["trixie", "forky", "sid"]
DEVUAN_RELEASES = ["excalibur", "forky", "ceres"]
UBUNTU_RELEASES = ["resolute", "stonking", "devel"]

DEBIAN_RELEASE_META = {
    "trixie": {"role": "stable",   "version": "13",   "topics": ["trixie"]},
    "forky":  {"role": "testing",  "version": "14",   "topics": ["forky"]},
    "sid":    {"role": "unstable", "version": None,   "topics": ["sid", "unstable"]},
}
DEVUAN_RELEASE_META = {
    "excalibur": {"role": "stable",   "debian_base": "trixie", "version": "6",  "topics": ["excalibur"]},
    "forky":     {"role": "testing",  "debian_base": "forky",  "version": None, "topics": ["forky"],
                  "note": "placeholder until Devuan names this release"},
    "ceres":     {"role": "unstable", "debian_base": "sid",    "version": None, "topics": ["ceres", "unstable"]},
}
UBUNTU_RELEASE_META = {
    "resolute": {"role": "stable",      "version": "26.04", "lts": True,  "topics": ["resolute"]},
    "stonking": {"role": "development", "version": "26.10", "lts": False, "topics": ["stonking"]},
    "devel":    {"role": "unstable",    "version": None,    "lts": False, "topics": ["devel", "unstable"],
                 "note": "rolling alias"},
}

UPSTREAMS = {
    "debian": {
        "kernel": "https://salsa.debian.org/kernel-team/linux",
        "cd":     "https://salsa.debian.org/images-team/debian-cd",
    },
    "devuan": {
        "kernel": "https://git.devuan.org/devuan/linux",
        "cd":     "https://git.devuan.org/devuan-packages/debian-cd",
    },
    "ubuntu": {
        "kernel": "https://kernel.ubuntu.com/git/ubuntu/ubuntu-devel.git",
        "cd":     "https://git.launchpad.net/~ubuntu-cdimage/ubuntu-cdimage",
    },
}

# Patchset support matrix: True = real content, False = scaffold only
PATCHSET_SUPPORT = {
    "xanmod":    {"amd64": True,  "arm64": True,  "armhf": False, "armel": False,
                  "riscv64": False, "ppc64el": False, "s390x": False,
                  "mips64el": False, "loong64": False, "i686": False, "i386": True},
    "liquorix":  {"amd64": True,  "arm64": True,  "armhf": True,  "armel": False,
                  "riscv64": False, "ppc64el": False, "s390x": False,
                  "mips64el": False, "loong64": False, "i686": False, "i386": True},
    "liqxanmod": {"amd64": True,  "arm64": True,  "armhf": False, "armel": False,
                  "riscv64": False, "ppc64el": False, "s390x": False,
                  "mips64el": False, "loong64": False, "i686": False, "i386": True},
}

# ---------------------------------------------------------------------------
# GitHub API helpers
# ---------------------------------------------------------------------------

def gh_api(method: str, path: str, data: Optional[dict] = None,
           dry_run: bool = False) -> Optional[dict]:
    """Call GitHub API with automatic rate limit handling."""
    if dry_run:
        print(f"  [dry-run] {method} {path}" + (f" {data}" if data else ""))
        return {"html_url": f"https://github.com/{ORG}/dry-run-repo"}

    cmd = ["gh", "api", "--method", method, path]
    if data:
        for k, v in data.items():
            cmd += ["-f", f"{k}={v}"]

    while True:
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            try:
                return json.loads(result.stdout)
            except json.JSONDecodeError:
                return {}

        # Check for rate limit
        if "rate limit" in result.stdout.lower() or "403" in result.stderr:
            # Get reset time
            rate = subprocess.run(
                ["gh", "api", "rate_limit"],
                capture_output=True, text=True
            )
            try:
                rd = json.loads(rate.stdout)
                reset = rd["resources"]["core"]["reset"]
                remaining = rd["resources"]["core"]["remaining"]
                wait = max(0, reset - int(time.time())) + 10
                print(f"\n  ⚠ Rate limited ({remaining} remaining). "
                      f"Waiting {wait}s (resets at {time.strftime('%H:%M:%S UTC', time.gmtime(reset))})...")
                time.sleep(wait)
                continue
            except Exception:
                print("  ⚠ Rate limited. Waiting 60s...")
                time.sleep(60)
                continue

        # Check if repo already exists (422 = already exists)
        if "422" in result.stderr or "already exists" in result.stdout.lower():
            return {"html_url": f"https://github.com/{ORG}/already-exists", "already_exists": True}

        print(f"  ✗ API error: {result.stderr.strip()[:100]}")
        return None


def repo_exists(name: str) -> bool:
    """Check if a repo already exists in the org."""
    result = subprocess.run(
        ["gh", "api", f"repos/{ORG}/{name}", "--jq", ".name"],
        capture_output=True, text=True
    )
    return result.returncode == 0


def create_repo(name: str, description: str, homepage: str,
                topics: list, dry_run: bool = False) -> bool:
    """Create a repo and set its topics. Returns True if created/exists."""
    if dry_run:
        print(f"  [dry-run] gh repo create {ORG}/{name}")
        print(f"  ✓ created: {name}")
        return True

    if repo_exists(name):
        print(f"  ↩ exists: {name}")
        return True

    # Use gh repo create CLI (handles auth correctly for org repos)
    cmd = [
        "gh", "repo", "create", f"{ORG}/{name}",
        "--public",
        "--description", description,
    ]
    if homepage:
        cmd += ["--homepage", homepage]

    while True:
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            print(f"  ✓ created: {name}")
            break
        if "rate limit" in result.stderr.lower() or "403" in result.stderr:
            rate = subprocess.run(["gh", "api", "rate_limit"],
                                  capture_output=True, text=True)
            try:
                rd = json.loads(rate.stdout)
                reset = rd["resources"]["core"]["reset"]
                wait = max(0, reset - int(time.time())) + 10
                print(f"\n  ⚠ Rate limited. Waiting {wait}s "
                      f"(resets at {time.strftime('%H:%M:%S UTC', time.gmtime(reset))})...")
                time.sleep(wait)
                continue
            except Exception:
                time.sleep(60)
                continue
        if "already exists" in result.stderr.lower() or "Name already exists" in result.stderr:
            print(f"  ↩ exists: {name}")
            break
        print(f"  ✗ failed: {name} — {result.stderr.strip()[:120]}")
        return False

    # Set topics (brief pause first)
    time.sleep(0.5)
    topic_str = " ".join(dict.fromkeys(t for t in topics if t))
    subprocess.run(
        ["gh", "repo", "edit", f"{ORG}/{name}"] +
        [f"--add-topic={t}" for t in topic_str.split()],
        capture_output=True
    )
    return True


# ---------------------------------------------------------------------------
# Repo definition builders
# ---------------------------------------------------------------------------

@dataclass
class RepoSpec:
    name: str
    description: str
    homepage: str
    topics: list


def build_repo_specs(arch: str) -> list:
    """Build the full list of RepoSpec for a given architecture."""
    specs = []
    base_topics = [arch, "i386" if arch == "i386" else arch, "x86" if arch in ("i386", "i686", "amd64") else ""]
    base_topics = [t for t in base_topics if t]

    # -----------------------------------------------------------------------
    # Debian individual repos
    # -----------------------------------------------------------------------
    for release in DEBIAN_RELEASES:
        meta = DEBIAN_RELEASE_META[release]
        role = meta["role"]
        topics = ["debian", arch, "linux-kernel", "x86" if arch in ("i386","i686","amd64") else arch, release]
        topics = list(dict.fromkeys(t for t in topics if t))

        # linux
        specs.append(RepoSpec(
            name=f"debian-linux-{arch}-{release}",
            description=f"Debian {release.capitalize()} {arch} port — i386-style kernel restoration for {arch} on Debian {release.capitalize()} ({role})",
            homepage=UPSTREAMS["debian"]["kernel"],
            topics=topics,
        ))
        # cd
        specs.append(RepoSpec(
            name=f"debian-cd-{arch}-{release}",
            description=f"Debian {release.capitalize()} {arch} CD image ({role})",
            homepage=UPSTREAMS["debian"]["cd"],
            topics=["debian", arch, "cd-image", release],
        ))
        # monorepo
        specs.append(RepoSpec(
            name=f"debian-{release}-{arch}",
            description=f"Unified Debian {release.capitalize()} {arch} port — merges linux kernel and CD image builds ({role})",
            homepage=UPSTREAMS["debian"]["kernel"],
            topics=["debian", arch, "linux-kernel", "cd-image", "monorepo", release],
        ))

    # Debian family bundles
    specs.append(RepoSpec(
        name=f"debian-linux-{arch}-trixie-forky-sid",
        description=f"Debian 32-bit {arch} Linux kernel family — Trixie, Forky, and Sid ports in one repo",
        homepage=UPSTREAMS["debian"]["kernel"],
        topics=["debian", arch, "linux-kernel", "monorepo", "trixie", "forky", "sid"],
    ))
    specs.append(RepoSpec(
        name=f"debian-cd-{arch}-trixie-forky-sid",
        description=f"Debian {arch} CD image family — Trixie, Forky, and Sid ports in one repo",
        homepage=UPSTREAMS["debian"]["cd"],
        topics=["debian", arch, "cd-image", "monorepo", "trixie", "forky", "sid"],
    ))
    specs.append(RepoSpec(
        name=f"debian-{arch}-trixie-forky-sid",
        description=f"Debian {arch} Linux kernel & CD image family bundle — Trixie, Forky, and Sid",
        homepage=UPSTREAMS["debian"]["kernel"],
        topics=["debian", arch, "linux-kernel", "cd-image", "monorepo", "trixie", "forky", "sid"],
    ))

    # -----------------------------------------------------------------------
    # Devuan individual repos
    # -----------------------------------------------------------------------
    for release in DEVUAN_RELEASES:
        meta = DEVUAN_RELEASE_META[release]
        role = meta["role"]
        base = meta["debian_base"]
        note = f" ({meta['note']})" if "note" in meta else ""
        topics = ["devuan", arch, "linux-kernel", release]

        specs.append(RepoSpec(
            name=f"devuan-linux-{arch}-{release}",
            description=f"Devuan {release.capitalize()} {arch} port — kernel for Devuan {release.capitalize()} ({role}, {base} base){note}",
            homepage=UPSTREAMS["devuan"]["kernel"],
            topics=topics,
        ))
        specs.append(RepoSpec(
            name=f"devuan-cd-{arch}-{release}",
            description=f"Devuan {release.capitalize()} {arch} CD image ({role}, {base} base){note}",
            homepage=UPSTREAMS["devuan"]["cd"],
            topics=["devuan", arch, "cd-image", release],
        ))
        specs.append(RepoSpec(
            name=f"devuan-{release}-{arch}",
            description=f"Unified Devuan {release.capitalize()} {arch} port — merges linux kernel and CD image builds ({role}, {base} base){note}",
            homepage=UPSTREAMS["devuan"]["kernel"],
            topics=["devuan", arch, "linux-kernel", "cd-image", "monorepo", release],
        ))

    # Devuan family bundles
    specs.append(RepoSpec(
        name=f"devuan-linux-{arch}-excalibur-forky-ceres",
        description=f"Devuan {arch} Linux kernel family — Excalibur, Forky, and Ceres ports in one repo",
        homepage=UPSTREAMS["devuan"]["kernel"],
        topics=["devuan", arch, "linux-kernel", "monorepo", "excalibur", "forky", "ceres"],
    ))
    specs.append(RepoSpec(
        name=f"devuan-cd-{arch}-excalibur-forky-ceres",
        description=f"Devuan {arch} CD image family — Excalibur, Forky, and Ceres ports in one repo",
        homepage=UPSTREAMS["devuan"]["cd"],
        topics=["devuan", arch, "cd-image", "monorepo", "excalibur", "forky", "ceres"],
    ))
    specs.append(RepoSpec(
        name=f"devuan-{arch}-excalibur-forky-ceres",
        description=f"Devuan {arch} Linux kernel & CD image family bundle — Excalibur, Forky, and Ceres",
        homepage=UPSTREAMS["devuan"]["kernel"],
        topics=["devuan", arch, "linux-kernel", "cd-image", "monorepo", "excalibur", "forky", "ceres"],
    ))

    # -----------------------------------------------------------------------
    # Ubuntu individual repos
    # -----------------------------------------------------------------------
    for release in UBUNTU_RELEASES:
        meta = UBUNTU_RELEASE_META[release]
        role = meta["role"]
        ver = f" {meta['version']}" if meta.get("version") else ""
        lts = " LTS" if meta.get("lts") else ""
        note = f" ({meta['note']})" if "note" in meta else ""
        topics = ["ubuntu", arch, "linux-kernel", release]

        specs.append(RepoSpec(
            name=f"ubuntu-linux-{arch}-{release}",
            description=f"Ubuntu {release.capitalize()}{ver}{lts} {arch} port — kernel for {arch} on Ubuntu {release.capitalize()} ({role}){note}",
            homepage=f"https://kernel.ubuntu.com/git/ubuntu/ubuntu-{release}.git",
            topics=topics,
        ))
        specs.append(RepoSpec(
            name=f"ubuntu-cd-{arch}-{release}",
            description=f"Ubuntu {release.capitalize()}{ver}{lts} {arch} CD image ({role}){note}",
            homepage=UPSTREAMS["ubuntu"]["cd"],
            topics=["ubuntu", arch, "cd-image", release],
        ))
        specs.append(RepoSpec(
            name=f"ubuntu-{release}-{arch}",
            description=f"Unified Ubuntu {release.capitalize()}{ver}{lts} {arch} port — merges linux kernel and CD image builds ({role}){note}",
            homepage=f"https://kernel.ubuntu.com/git/ubuntu/ubuntu-{release}.git",
            topics=["ubuntu", arch, "linux-kernel", "cd-image", "monorepo", release],
        ))

    # Ubuntu family bundles
    specs.append(RepoSpec(
        name=f"ubuntu-linux-{arch}-resolute-stonking-devel",
        description=f"Ubuntu {arch} Linux kernel family — Resolute, Stonking, and Devel ports in one repo",
        homepage="https://kernel.ubuntu.com/git/ubuntu/ubuntu-devel.git",
        topics=["ubuntu", arch, "linux-kernel", "monorepo", "resolute", "stonking", "devel"],
    ))
    specs.append(RepoSpec(
        name=f"ubuntu-cd-{arch}-resolute-stonking-devel",
        description=f"Ubuntu {arch} CD image family — Resolute, Stonking, and Devel ports in one repo",
        homepage=UPSTREAMS["ubuntu"]["cd"],
        topics=["ubuntu", arch, "cd-image", "monorepo", "resolute", "stonking", "devel"],
    ))
    specs.append(RepoSpec(
        name=f"ubuntu-{arch}-resolute-stonking-devel",
        description=f"Ubuntu {arch} Linux kernel & CD image family bundle — Resolute, Stonking, and Devel",
        homepage="https://kernel.ubuntu.com/git/ubuntu/ubuntu-devel.git",
        topics=["ubuntu", arch, "linux-kernel", "cd-image", "monorepo", "resolute", "stonking", "devel"],
    ))

    # -----------------------------------------------------------------------
    # Hub repos (5)
    # -----------------------------------------------------------------------
    specs.append(RepoSpec(
        name=f"{arch}-deb-family",
        description=f"Debian-family {arch} umbrella — Debian, Devuan, and Ubuntu {arch} kernel & CD image ports unified in one repo",
        homepage=UPSTREAMS["debian"]["kernel"],
        topics=["debian", "devuan", "ubuntu", arch, "linux-kernel", "cd-image", "monorepo", "deb-family"],
    ))
    specs.append(RepoSpec(
        name=f"debian-{arch}-kernel-base",
        description=f"Debian {arch} Linux kernel base — Trixie (stable), Forky (testing), and Sid (unstable) branches with upstream history from Salsa",
        homepage=UPSTREAMS["debian"]["kernel"],
        topics=["debian", arch, "linux-kernel", "trixie", "forky", "sid"],
    ))
    specs.append(RepoSpec(
        name=f"devuan-{arch}-kernel-base",
        description=f"Devuan {arch} kernel overlay — Devuan-specific config fragments and patches layered on Debian's kernel base (excalibur/forky/ceres)",
        homepage=UPSTREAMS["devuan"]["kernel"],
        topics=["devuan", arch, "linux-kernel", "excalibur", "forky", "ceres"],
    ))
    specs.append(RepoSpec(
        name=f"ubuntu-{arch}-kernel-base",
        description=f"Ubuntu {arch} Linux kernel base — Resolute (26.04 LTS), Stonking (26.10), and Devel (rolling) branches",
        homepage="https://kernel.ubuntu.com/git/ubuntu/ubuntu-devel.git",
        topics=["ubuntu", arch, "linux-kernel", "resolute", "stonking", "devel"],
    ))
    specs.append(RepoSpec(
        name=f"{arch}-deb-linux-kernel-base",
        description=f"Debian-family {arch} Linux kernel patchset orchestration — XanMod, Liquorix, and Liqxanmod overlays across Debian, Devuan, and Ubuntu",
        homepage=UPSTREAMS["debian"]["kernel"],
        topics=["debian", "devuan", "ubuntu", arch, "linux-kernel", "xanmod", "liquorix", "liqxanmod", "monorepo"],
    ))

    return specs


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Create Debian-family arch repos")
    parser.add_argument("--arch", nargs="+", required=True,
                        help="Architecture(s) to create repos for")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print what would be created without making API calls")
    parser.add_argument("--skip-existing", action="store_true", default=True,
                        help="Skip repos that already exist (default: True)")
    args = parser.parse_args()

    if not TOKEN and not args.dry_run:
        # gh CLI handles auth — just verify it works
        result = subprocess.run(["gh", "auth", "status"], capture_output=True, text=True)
        if result.returncode != 0:
            print("✗ Not authenticated. Run: gh auth login")
            sys.exit(1)

    total_created = 0
    total_skipped = 0
    total_failed = 0

    for arch in args.arch:
        print(f"\n{'='*60}")
        print(f"Architecture: {arch}")
        print(f"{'='*60}")

        specs = build_repo_specs(arch)
        print(f"Repos to create: {len(specs)}")

        for i, spec in enumerate(specs, 1):
            print(f"\n[{i}/{len(specs)}] {spec.name}")
            ok = create_repo(
                name=spec.name,
                description=spec.description,
                homepage=spec.homepage,
                topics=spec.topics,
                dry_run=args.dry_run,
            )
            if ok:
                total_created += 1
            else:
                total_failed += 1

            # Pace requests to avoid secondary rate limits
            # GitHub allows ~30 mutations/minute sustained
            if not args.dry_run and i % 10 == 0:
                print(f"  … pausing 20s to respect secondary rate limits …")
                time.sleep(20)

    print(f"\n{'='*60}")
    print(f"Done. Created/verified: {total_created}  Failed: {total_failed}")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
