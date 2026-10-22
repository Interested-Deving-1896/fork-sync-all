#!/usr/bin/env python3
"""Safe, provider-neutral local Git workspace operations for agents.

This helper deliberately has no push, merge, reset, checkout, or branch-write
command. Fetch updates remote-tracking refs only; it does not alter the working
tree or discard local changes.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit

REPO_COORDINATES = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
ALLOWED_SCHEMES = {"https", "ssh", "git"}


class WorkspaceError(Exception):
    """Expected, safe-to-report workspace error."""


def validate_coordinates(value: str) -> str:
    value = value.strip()
    if not REPO_COORDINATES.fullmatch(value):
        raise WorkspaceError("repository must use owner/name coordinates")
    if value in {".", ".."} or any(part in {".", ".."} for part in value.split("/")):
        raise WorkspaceError("repository coordinates contain an invalid path segment")
    return value


def validate_remote_url(value: str) -> str:
    value = value.strip()
    parsed = urlsplit(value)
    if parsed.scheme not in ALLOWED_SCHEMES or not parsed.hostname:
        raise WorkspaceError("remote URL must use https://, ssh://, or git:// with a host")
    if parsed.username or parsed.password:
        raise WorkspaceError("remote URLs must not embed credentials")
    if parsed.query or parsed.fragment:
        raise WorkspaceError("remote URL must not contain a query or fragment")
    if parsed.scheme == "https" and parsed.port not in (None, 443):
        raise WorkspaceError("HTTPS remote URLs may only use the default port")
    if parsed.path in {"", "/"} or parsed.path.startswith("//"):
        raise WorkspaceError("remote URL must identify a repository path")
    return value


def run_git(args: list[str], cwd: Path | None = None) -> str:
    try:
        result = subprocess.run(
            ["git", *args], cwd=str(cwd) if cwd else None,
            text=True, capture_output=True, check=False,
        )
    except FileNotFoundError as exc:
        raise WorkspaceError("Git is unavailable; API-only access cannot run local Git operations") from exc
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown Git error"
        raise WorkspaceError(f"git {' '.join(args[:2])} failed: {detail}")
    return result.stdout.strip()


def require_repository(path: Path) -> Path:
    resolved = path.expanduser().resolve()
    if not resolved.exists() or not resolved.is_dir():
        raise WorkspaceError(f"workspace directory does not exist: {resolved}")
    run_git(["rev-parse", "--show-toplevel"], cwd=resolved)
    return resolved


def status(path: Path) -> dict[str, object]:
    root = require_repository(path)
    head = run_git(["rev-parse", "HEAD"], cwd=root)
    branch = run_git(["branch", "--show-current"], cwd=root)
    porcelain = run_git(["status", "--porcelain=v1", "--untracked-files=all"], cwd=root)
    remote = run_git(["remote", "get-url", "origin"], cwd=root) if run_git(["remote"], cwd=root) else None
    return {
        "workspace": str(root),
        "head": head,
        "branch": branch or None,
        "origin": remote,
        "dirty": bool(porcelain),
        "changes": porcelain.splitlines(),
        "read_only": True,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("validate", help="validate repository coordinates or a remote URL")
    check.add_argument("--coordinates")
    check.add_argument("--url")
    clone = sub.add_parser("clone", help="clone into a new or empty destination")
    clone.add_argument("--url", required=True)
    clone.add_argument("--destination", required=True, type=Path)
    fetch = sub.add_parser("fetch", help="fetch origin without changing the working tree")
    fetch.add_argument("workspace", type=Path)
    stat = sub.add_parser("status", help="report local branch, HEAD, remote, and dirty state")
    stat.add_argument("workspace", type=Path)
    diff = sub.add_parser("diff", help="show a read-only diff summary")
    diff.add_argument("workspace", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "validate":
            if bool(args.coordinates) == bool(args.url):
                raise WorkspaceError("provide exactly one of --coordinates or --url")
            value = validate_coordinates(args.coordinates) if args.coordinates else validate_remote_url(args.url)
            print(json.dumps({"valid": True, "value": value}, sort_keys=True))
        elif args.command == "clone":
            url = validate_remote_url(args.url)
            dest = args.destination.expanduser().resolve()
            if dest.exists():
                if not dest.is_dir() or any(dest.iterdir()):
                    raise WorkspaceError("clone destination must not exist or must be an empty directory")
            else:
                dest.parent.mkdir(parents=True, exist_ok=True)
            run_git(["clone", "--", url, str(dest)])
            print(json.dumps({"cloned": True, "workspace": str(dest), "remote": url}, sort_keys=True))
        elif args.command == "fetch":
            root = require_repository(args.workspace)
            if not run_git(["remote"], cwd=root):
                raise WorkspaceError("repository has no configured remote; refusing implicit remote setup")
            run_git(["fetch", "origin"], cwd=root)
            print(json.dumps({"fetched": True, "workspace": str(root), "working_tree_changed": False}, sort_keys=True))
        elif args.command == "status":
            print(json.dumps(status(args.workspace), indent=2, sort_keys=True))
        elif args.command == "diff":
            root = require_repository(args.workspace)
            unstaged = run_git(["diff", "--stat", "--"], cwd=root)
            staged = run_git(["diff", "--cached", "--stat", "--"], cwd=root)
            print(json.dumps({"workspace": str(root), "unstaged": unstaged, "staged": staged, "read_only": True}, indent=2, sort_keys=True))
        return 0
    except WorkspaceError as exc:
        print(json.dumps({"error": str(exc)}, sort_keys=True), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
