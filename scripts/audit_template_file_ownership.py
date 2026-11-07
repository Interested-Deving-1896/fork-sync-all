#!/usr/bin/env python3
"""Read-only, fail-closed audit of template-sync ownership for tracked files.

A file is considered cleanup-eligible only when its complete path history is
available, its earliest recorded addition is a template-sync commit, and every
subsequent commit touching that path is also a template-sync commit. This is
deliberately stricter than checking only the latest commit: a consumer edit at
any point permanently disqualifies the path from automatic cleanup.

This tool never deletes or modifies files. Run it against a full local clone of
one consumer repository and pass exact candidate paths.
"""
from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout


def audit_path(repo: Path, path: str) -> dict[str, Any]:
    path = path.strip()
    if not path or path.startswith("/") or ".." in Path(path).parts:
        return {"path": path, "eligible": False, "reason": "invalid-relative-path"}

    shallow = git(repo, "rev-parse", "--is-shallow-repository").strip()
    if shallow != "false":
        return {"path": path, "eligible": False, "reason": "shallow-history"}

    tracked = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "--error-unmatch", "--", path],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if tracked.returncode:
        return {"path": path, "eligible": False, "reason": "not-tracked"}

    history = git(
        repo, "log", "--follow", "--reverse",
        "--format=%H%x09%P%x09%s", "--", path,
    )
    commits = [line.split("\t", 2) for line in history.splitlines() if line]
    if not commits:
        return {"path": path, "eligible": False, "reason": "history-unavailable"}

    non_sync: list[str] = []
    merge_commits: list[str] = []
    for commit in commits:
        if len(commit) != 3:
            return {"path": path, "eligible": False, "reason": "unparseable-history"}
        sha, parents, subject = commit
        if len(parents.split()) > 1:
            merge_commits.append(sha)
        if not (
            subject.startswith("chore: sync template file ")
            and subject.endswith(" [skip ci]")
        ):
            non_sync.append(sha)

    if merge_commits:
        return {
            "path": path, "eligible": False, "reason": "ambiguous-merge-history",
            "merge_commits": merge_commits,
        }
    if non_sync:
        return {
            "path": path, "eligible": False, "reason": "consumer-or-unverified-history",
            "non_sync_commits": non_sync,
        }

    # The first recorded path change must itself be a template-sync addition.
    first_sha = commits[0][0]
    first_change = git(
        repo, "diff-tree", "--no-commit-id", "--name-status", "-r", first_sha
    ).splitlines()
    if not any(line.endswith("\t" + path) and line.startswith("A\t") for line in first_change):
        return {
            "path": path, "eligible": False,
            "reason": "first-change-not-proven-addition",
            "first_commit": first_sha,
        }

    return {
        "path": path, "eligible": True,
        "reason": "complete-template-only-path-history",
        "baseline_commit": first_sha,
        "latest_commit": commits[-1][0],
        "evidence_commits": len(commits),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True, help="Full local clone of one consumer repository")
    parser.add_argument("--path", action="append", required=True, help="Exact repository-relative candidate path; repeatable")
    args = parser.parse_args()
    repo = args.repo.resolve()
    if not (repo / ".git").exists() and not (repo / ".git").is_file():
        parser.error("--repo must be a Git working tree")
    results = [audit_path(repo, path) for path in args.path]
    print(json.dumps({"repository": str(repo), "mode": "read-only", "results": results}, indent=2))
    return 0 if all(item["eligible"] for item in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
