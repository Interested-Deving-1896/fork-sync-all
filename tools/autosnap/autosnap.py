#!/usr/bin/env python3
"""
autosnap.py — Python core for autosnap (btrfs-dwarfs-framework edition).

Backends: bdfs (primary), btrfs (fallback).
All other backends from the standalone autosnap tool are intentionally
excluded — this build is scoped to the btrfs+DwarFS stack.
"""

from __future__ import annotations

import argparse
import datetime
import logging
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

VERSION = "0.1.0"
CONF_FILE = Path(os.environ.get("AUTOSNAP_CONF", "/etc/autosnap.conf"))
STATE_DIR = Path(os.environ.get("AUTOSNAP_STATE_DIR", "/var/lib/autosnap"))
# Installed under /usr/lib/bdfs/autosnap/ to co-locate with the framework
LIBDIR = Path(os.environ.get("AUTOSNAP_LIBDIR", "/usr/lib/bdfs/autosnap"))

log = logging.getLogger("autosnap")


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

class Config:
    DEFAULTS: dict[str, object] = {
        "BACKEND": "",
        "MAX_SNAPSHOTS": 5,
        "RECORD_PACKAGES": True,
        "SKIP_ENV_VAR": "SKIP_AUTOSNAP",
        "DESCRIPTION_TEMPLATE": "autosnap: pre {action} on {date}",
        "BDFS_BIN": "bdfs",
        "BDFS_SOCKET": "/run/bdfs/bdfs.sock",
        "BDFS_PARTITION_UUID": "",
        "BDFS_DEMOTE_ON_PRUNE": False,
        "BDFS_DEMOTE_COMPRESSION": "zstd",
    }

    def __init__(self, path: Path = CONF_FILE) -> None:
        self._data: dict[str, str] = {}
        if path.exists():
            self._load(path)

    def _load(self, path: Path) -> None:
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                k, _, v = line.partition("=")
                self._data[k.strip()] = v.strip().strip('"').strip("'")

    def get(self, key: str) -> object:
        raw = self._data.get(key)
        default = self.DEFAULTS.get(key)
        if raw is None:
            return default
        if isinstance(default, bool):
            return raw.lower() in ("true", "1", "yes")
        if isinstance(default, int):
            try:
                return int(raw)
            except ValueError:
                return default
        return raw

    def __getattr__(self, key: str) -> object:
        upper = key.upper()
        if upper in self.DEFAULTS:
            return self.get(upper)
        raise AttributeError(key)


# ---------------------------------------------------------------------------
# Environment guards
# ---------------------------------------------------------------------------

def should_skip(cfg: Config) -> bool:
    skip_var = str(cfg.SKIP_ENV_VAR)
    if skip_var and skip_var in os.environ:
        log.info("Skipping: $%s is set", skip_var)
        return True
    try:
        r = subprocess.run(
            ["findmnt", "-no", "FSTYPE", "/"],
            capture_output=True, text=True, timeout=5,
        )
        if r.stdout.strip() == "overlay":
            log.info("Skipping: root is an overlay filesystem (Live CD?)")
            return True
    except Exception:
        pass
    return False


# ---------------------------------------------------------------------------
# Backend auto-detection — bdfs first, raw btrfs as fallback
# ---------------------------------------------------------------------------

def detect_backend(cfg: Config) -> str:
    forced = str(cfg.BACKEND)
    if forced:
        log.debug("Backend forced to '%s' by config", forced)
        return forced

    bdfs_bin = str(cfg.BDFS_BIN)
    bdfs_socket = Path(str(cfg.BDFS_SOCKET))

    if shutil.which(bdfs_bin) and bdfs_socket.is_socket():
        log.info("Auto-detected backend: bdfs")
        return "bdfs"

    # Fallback: raw btrfs
    try:
        r = subprocess.run(
            ["findmnt", "-no", "FSTYPE", "/"],
            capture_output=True, text=True, timeout=5,
        )
        fstype = r.stdout.strip()
    except Exception:
        fstype = "unknown"

    if fstype == "btrfs" and shutil.which("btrfs"):
        log.warning(
            "bdfs daemon not reachable — falling back to raw btrfs snapshots. "
            "Start bdfs_daemon for full snapshot lifecycle management."
        )
        log.info("Auto-detected backend: btrfs (fallback)")
        return "btrfs"

    log.error(
        "No usable snapshot backend found. "
        "Either start bdfs_daemon or ensure the root filesystem is btrfs."
    )
    sys.exit(1)


def resolve_partition_uuid(cfg: Config) -> str:
    """
    Return the bdfs partition UUID to use for snapshotting.

    If BDFS_PARTITION_UUID is set in config, return it directly.
    Otherwise query `bdfs partition list --json`:
      - exactly one partition  → use it automatically
      - zero partitions        → fatal: nothing registered
      - multiple partitions    → fatal: ambiguous; require explicit config
    """
    explicit = str(cfg.BDFS_PARTITION_UUID).strip()
    if explicit:
        log.debug("Using configured BDFS_PARTITION_UUID: %s", explicit)
        return explicit

    bdfs_bin = str(cfg.BDFS_BIN)
    try:
        r = subprocess.run(
            [bdfs_bin, "partition", "list", "--json"],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode != 0:
            log.error("bdfs partition list failed: %s", r.stderr.strip())
            sys.exit(1)
    except FileNotFoundError:
        log.error("bdfs binary not found: %s", bdfs_bin)
        sys.exit(1)
    except Exception as exc:
        log.error("bdfs partition list error: %s", exc)
        sys.exit(1)

    import re
    uuids = re.findall(
        r'"uuid"\s*:\s*"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"',
        r.stdout,
    )

    if len(uuids) == 0:
        log.error(
            "No bdfs partitions found. "
            "Register a partition with 'bdfs partition add' first."
        )
        sys.exit(1)

    if len(uuids) == 1:
        log.info("Auto-detected single bdfs partition: %s", uuids[0])
        return uuids[0]

    # Multiple partitions — require explicit config
    log.error(
        "Multiple bdfs partitions found (%d). "
        "Set BDFS_PARTITION_UUID in /etc/autosnap.conf to select one.",
        len(uuids),
    )
    for u in uuids:
        log.error("  %s", u)
    sys.exit(1)


# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

def state_write(key: str, value: str) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    (STATE_DIR / key).write_text(value)


def state_read(key: str) -> str:
    p = STATE_DIR / key
    return p.read_text().strip() if p.exists() else ""


def state_delete(key: str) -> None:
    (STATE_DIR / key).unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Description builder
# ---------------------------------------------------------------------------

def build_description(template: str, action: str) -> str:
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    return template.replace("{action}", action).replace("{date}", now)


# ---------------------------------------------------------------------------
# Package list reader
# ---------------------------------------------------------------------------

def read_packages_stdin() -> str:
    if sys.stdin.isatty():
        return os.environ.get("AUTOSNAP_PACKAGES", "")
    lines = sys.stdin.read().splitlines()
    pkgs = []
    for line in lines:
        name = Path(line.strip()).name
        name = re.sub(r'\.(deb|rpm|pkg\.tar\.[a-z]+)$', '', name)
        if name:
            pkgs.append(name)
    return " ".join(pkgs) or os.environ.get("AUTOSNAP_PACKAGES", "")


# ---------------------------------------------------------------------------
# Shell backend dispatcher
# ---------------------------------------------------------------------------

class ShellBackend:
    """Sources common.sh + backend script and calls backend_<action>."""

    def __init__(self, name: str, cfg: Config) -> None:
        self.name = name
        self.cfg = cfg
        self._script = LIBDIR / "backends" / f"{name}.sh"
        if not self._script.exists():
            src = Path(__file__).parent / "backends" / f"{name}.sh"
            if src.exists():
                self._script = src

    def _common(self) -> Path:
        c = LIBDIR / "lib" / "common.sh"
        if not c.exists():
            c = Path(__file__).parent / "lib" / "common.sh"
        return c

    def _run(self, action: str, *args: str) -> int:
        env = os.environ.copy()
        libdir = LIBDIR if LIBDIR.exists() else Path(__file__).parent

        # Resolve partition UUID once here so the shell backend doesn't need
        # to re-implement the multi-partition detection logic.
        partition_uuid = (
            resolve_partition_uuid(self.cfg)
            if self.name == "bdfs"
            else ""
        )

        env.update({
            "AUTOSNAP_LIBDIR":         str(libdir),
            "AUTOSNAP_STATE_DIR":      str(STATE_DIR),
            "AUTOSNAP_DEBUG":          "1" if log.isEnabledFor(logging.DEBUG) else "0",
            "BACKEND":                 str(self.cfg.BACKEND),
            "MAX_SNAPSHOTS":           str(self.cfg.MAX_SNAPSHOTS),
            "RECORD_PACKAGES":         "true" if self.cfg.RECORD_PACKAGES else "false",
            "BDFS_BIN":                str(self.cfg.BDFS_BIN),
            "BDFS_SOCKET":             str(self.cfg.BDFS_SOCKET),
            "BDFS_PARTITION_UUID":     partition_uuid,
            "BDFS_DEMOTE_ON_PRUNE":
                "true" if self.cfg.BDFS_DEMOTE_ON_PRUNE else "false",
            "BDFS_DEMOTE_COMPRESSION": str(self.cfg.BDFS_DEMOTE_COMPRESSION),
        })
        arg_str = " ".join(f'"{a}"' for a in args)
        script = (
            f'. "{self._common()}"\n'
            f'. "{self._script}"\n'
            f'backend_{action} {arg_str}\n'
        )
        return subprocess.run(["sh", "-s"], input=script.encode(), env=env).returncode

    def pre(self, desc: str, packages: str) -> int:
        return self._run("pre", desc, packages)

    def post(self, desc: str) -> int:
        return self._run("post", desc)

    def list(self) -> int:
        return self._run("list")

    def delete(self, snap_id: str) -> int:
        return self._run("delete", snap_id)

    def rollback(self, snap_id: str) -> int:
        return self._run("rollback", snap_id)

    def status(self, pre: str = "", post: str = "") -> int:
        return self._run("status", pre, post)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="autosnap",
        description=(
            "Package-manager snapshot hook for btrfs-dwarfs-framework. "
            "Primary backend: bdfs. Fallback: raw btrfs subvolumes."
        ),
    )
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--config", metavar="FILE")
    parser.add_argument("--backend", metavar="NAME",
                        choices=["bdfs", "btrfs"],
                        help="Override backend")

    sub = parser.add_subparsers(dest="command", metavar="command")

    p = sub.add_parser("pre",  help="Pre-operation snapshot")
    p.add_argument("pm", nargs="?", default="unknown")

    p = sub.add_parser("post", help="Post-operation snapshot")
    p.add_argument("pm", nargs="?", default="unknown")

    sub.add_parser("list",    help="List autosnap snapshots")

    p = sub.add_parser("delete",   help="Delete a snapshot")
    p.add_argument("id")

    p = sub.add_parser("rollback", help="Roll back to a snapshot")
    p.add_argument("id")

    p = sub.add_parser("status",   help="Show diff between snapshots")
    p.add_argument("pre",  nargs="?", default="")
    p.add_argument("post", nargs="?", default="")

    sub.add_parser("detect",  help="Print auto-detected backend")
    sub.add_parser("version", help="Print version")

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="autosnap: %(message)s",
        stream=sys.stderr,
    )

    if not args.command:
        parser.print_help()
        sys.exit(1)

    if args.command == "version":
        print(f"autosnap {VERSION} (btrfs-dwarfs-framework)")
        return

    conf_path = Path(args.config) if getattr(args, "config", None) else CONF_FILE
    cfg = Config(conf_path)
    if getattr(args, "backend", None):
        cfg._data["BACKEND"] = args.backend

    if args.command == "detect":
        print(f"Backend: {detect_backend(cfg)}")
        return

    if args.command in ("pre", "post") and should_skip(cfg):
        sys.exit(0)

    backend_name = detect_backend(cfg)
    # Export PM name for shell backend scripts
    os.environ["AUTOSNAP_PM"] = getattr(args, "pm", "unknown")
    backend = ShellBackend(backend_name, cfg)

    if args.command == "pre":
        packages = read_packages_stdin()
        desc = build_description(str(cfg.DESCRIPTION_TEMPLATE), args.pm)
        rc = backend.pre(desc, packages)
    elif args.command == "post":
        desc = build_description(str(cfg.DESCRIPTION_TEMPLATE), args.pm)
        rc = backend.post(desc)
    elif args.command == "list":
        rc = backend.list()
    elif args.command == "delete":
        rc = backend.delete(args.id)
    elif args.command == "rollback":
        if os.geteuid() != 0:
            log.error("rollback requires root privileges")
            sys.exit(1)
        rc = backend.rollback(args.id)
    elif args.command == "status":
        rc = backend.status(args.pre, args.post)
    else:
        parser.print_help()
        sys.exit(1)

    sys.exit(rc)


if __name__ == "__main__":
    main()
