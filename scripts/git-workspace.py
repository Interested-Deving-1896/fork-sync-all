#!/usr/bin/env python3
"""Safe, provider-neutral local Git workspace inspection and fetch helper.

This tool never pushes, merges, resets, checks out branches, or creates forks.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit


class WorkspaceError(Exception):
    """Expected, user-facing validation or Git operation failure."""


REPOSITORY_PATH = re.compile(r"^/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?/?$")
HOST = re.compile(r"^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$")


def emit(payload: dict[str, object], code: int = 0) -> None:
    print(json.dumps(payload, indent=2, sort_keys=True))
    raise SystemExit(code)


def validate_repository_url(value: str) -> str:
    """Accept a credential-free HTTPS URL for exactly one owner/project path."""
    if not isinstance(value, str) or not value.strip():
        raise WorkspaceError("repository URL must be a non-empty HTTPS URL")
    parsed = urlsplit(value.strip())
    if (
        parsed.scheme.lower() != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.port is not None
        or parsed.query
        or parsed.fragment
        or not HOST.fullmatch(parsed.hostname)
        or not REPOSITORY_PATH.fullmatch(parsed.path)
    ):
        raise WorkspaceError(
            "repository URL must be https://host/owner/repository[.git] "
            "without credentials, ports, query, or fragment"
        )
    owner, repository = parsed.path.strip("/").split("/", 1)
    repository = repository.removesuffix(".git")
    if owner in {".", ".."} or repository in {".", ".."}:
        raise WorkspaceError("repository path components may not be dot segments")
    return f"https://{parsed.hostname.lower()}/{owner}/{repository}.git"


def run_git(args: list[str], *, cwd: Path | None = None) -> str:
    if not shutil.which("git"):
        raise WorkspaceError("Git is unavailable; use the repository host's API/GUI instead")
    try:
        completed = subprocess.run(
            ["git", *args],
            cwd=str(cwd) if cwd else None,
            check=False,
            capture_output=True,
            text=True,
            timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise WorkspaceError(f"Git command could not complete: {exc}") from exc
    if completed.returncode:
        detail = (completed.stderr or completed.stdout).strip()
        raise WorkspaceError(detail or f"git {' '.join(args)} failed")
    return completed.stdout.strip()


def repo_root(path: Path) -> Path:
    candidate = path.expanduser().absolute()
    root = run_git(["-C", str(candidate), "rev-parse", "--show-toplevel"])
    return Path(root).resolve()


def origin_url(root: Path) -> str:
    value = run_git(["-C", str(root), "remote", "get-url", "origin"])
    return validate_repository_url(value)


def inspect(path: Path) -> dict[str, object]:
    root = repo_root(path)
    origin = origin_url(root)
    branch = run_git(["-C", str(root), "symbolic-ref", "--short", "-q", "HEAD"])
    head = run_git(["-C", str(root), "rev-parse", "--verify", "HEAD"])
    porcelain = run_git(
        ["-C", str(root), "status", "--porcelain=v1", "--untracked-files=normal"]
    )
    return {
        "ok": True,
        "workspace": str(root),
        "origin": origin,
        "branch": branch or None,
        "head": head,
        "detached_head": not bool(branch),
        "working_tree_clean": not bool(porcelain),
        "changes": porcelain.splitlines() if porcelain else [],
        "operations_performed": ["inspect"],
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("capabilities", help="report locally available Git tooling")
    clone = commands.add_parser("clone", help="clone an HTTPS repository to a new path")
    clone.add_argument("url")
    clone.add_argument("--destination", required=True, type=Path)
    for name, help_text in (
        ("status", "inspect origin, branch, HEAD, and working-tree state"),
        ("fetch", "fetch origin without changing the checked-out files or branch"),
        ("diff", "show unstaged and staged local differences"),
    ):
        command = commands.add_parser(name, help=help_text)
        command.add_argument("path", type=Path)
    return parser


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "capabilities":
            git_available = shutil.which("git") is not None
            gh_available = shutil.which("gh") is not None
            emit(
                {
                    "ok": True,
                    "git_available": git_available,
                    "github_cli_available": gh_available,
                    "local_workspace_operations_available": git_available,
                    "fallback": (
                        "local Git operations available"
                        if git_available
                        else "use the configured provider API or web interface; "
                        "API access itself is not tested by this command"
                    ),
                }
            )
        if args.command == "clone":
            url = validate_repository_url(args.url)
            destination = args.destination.expanduser().absolute()
            if destination.exists() or destination.is_symlink():
                raise WorkspaceError(
                    f"clone destination already exists; refusing to reuse or overwrite it: {destination}"
                )
            destination.parent.mkdir(parents=True, exist_ok=True)
            run_git(["clone", "--", url, str(destination)])
            emit(
                {
                    "ok": True,
                    "workspace": str(destination.resolve()),
                    "origin": url,
                    "operations_performed": ["clone"],
                    "writes_remote": False,
                    "note": "No fork, push, merge, reset, or branch switch was performed.",
                }
            )
        root = repo_root(args.path)
        if args.command == "status":
            emit(inspect(root))
        if args.command == "fetch":
            before = inspect(root)
            run_git(["-C", str(root), "fetch", "origin"])
            after = inspect(root)
            emit(
                {
                    "ok": True,
                    "before": before,
                    "after": after,
                    "operations_performed": ["fetch origin", "inspect"],
                    "working_tree_modified_by_helper": False,
                    "writes_remote": False,
                }
            )
        if args.command == "diff":
            staged = run_git(["-C", str(root), "diff", "--cached", "--"])
            unstaged = run_git(["-C", str(root), "diff", "--"])
            emit(
                {
                    "ok": True,
                    "workspace": str(root),
                    "staged_diff": staged,
                    "unstaged_diff": unstaged,
                    "operations_performed": ["diff --cached", "diff"],
                    "writes_remote": False,
                }
            )
    except WorkspaceError as exc:
        emit({"ok": False, "error": str(exc)}, 1)


if __name__ == "__main__":
    main()
