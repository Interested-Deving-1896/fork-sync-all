#!/usr/bin/env python3
"""Read-only Git branch inventory and relationship report.

This tool never checks out branches, fetches, pushes, merges, rebases, resets,
or deletes refs. It reports local Git state only; remote state may be stale.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from typing import Any


def git(*args: str) -> str:
    result = subprocess.run(
        ["git", *args], text=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, check=False,
    )
    if result.returncode:
        detail = result.stderr.strip() or f"git {' '.join(args)} failed"
        raise RuntimeError(detail)
    return result.stdout


def repo_root() -> str:
    return git("rev-parse", "--show-toplevel").strip()


def inventory() -> dict[str, Any]:
    fmt = "%(refname)%00%(objectname)%00%(upstream:short)%00%(upstream:track)%00%(committerdate:iso-strict)%00%(subject)%00%(HEAD)"
    raw = git("for-each-ref", f"--format={fmt}", "refs/heads", "refs/remotes")
    branches = []
    for line in raw.splitlines():
        fields = line.split("\0")
        if len(fields) != 7:
            continue
        name, sha, upstream, tracking, committed, subject, head = fields
        # Skip only the remote's symbolic default-branch pointer. A real local
        # branch or remote branch may legitimately have a path ending in /HEAD.
        if name.startswith("refs/remotes/") and name.count("/") == 3 and name.endswith("/HEAD"):
            continue
        local = name.startswith("refs/") is False and not name.startswith("origin/")
        if name.startswith("refs/"):
            local = name.startswith("refs/heads/")
        if name.startswith("refs/heads/"):
            name = name.removeprefix("refs/heads/")
        elif name.startswith("refs/remotes/"):
            name = name.removeprefix("refs/remotes/")
            local = False
        branches.append({
            "name": name,
            "ref_kind": "local" if local else "remote_tracking",
            "sha": sha,
            "upstream": upstream or None,
            "tracking": tracking.strip() or None,
            "last_commit_date": committed or None,
            "last_commit_subject": subject or None,
            "is_current": head == "*",
        })
    branches.sort(key=lambda b: (b["ref_kind"] != "local", b["name"]))
    return {
        "repository_root": repo_root(),
        "current_branch": git("branch", "--show-current").strip() or None,
        "default_source_policy": "main",
        "default_integration_target_policy": "main",
        "remote_state_note": "Remote-tracking refs are local snapshots and may be stale.",
        "branches": branches,
    }


def relationships(data: dict[str, Any]) -> dict[str, Any]:
    local_names = {
        branch["name"] for branch in data["branches"]
        if branch["ref_kind"] == "local"
    }
    edges = []
    for branch in data["branches"]:
        if branch["ref_kind"] != "local":
            continue
        upstream = branch["upstream"]
        if upstream:
            candidate = upstream
            if candidate in local_names:
                edges.append({
                    "from": branch["name"],
                    "to": candidate,
                    "kind": "configured_upstream",
                    "evidence": "Git branch upstream configuration",
                })
            else:
                edges.append({
                    "from": branch["name"],
                    "to": upstream,
                    "kind": "configured_upstream_external",
                    "evidence": "Git branch upstream configuration",
                })
        if branch["name"] != "main" and "main" in local_names and not upstream:
            edges.append({
                "from": "main",
                "to": branch["name"],
                "kind": "default_policy_source_only",
                "evidence": "Policy default; not proof of ancestry or branch creation point",
            })
    return {**data, "relationships": edges}


def explain(data: dict[str, Any], name: str) -> dict[str, Any]:
    for branch in data["branches"]:
        if branch["name"] == name:
            related = [
                edge for edge in data.get("relationships", [])
                if edge.get("from") == name or edge.get("to") == name
            ]
            return {"branch": branch, "relationships": related}
    raise RuntimeError(f"Branch not found in local inventory: {name}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Read-only local branch inventory and relationship graph."
    )
    parser.add_argument("command", choices=("inventory", "graph", "status", "explain"))
    parser.add_argument("branch", nargs="?", help="branch name for explain")
    parser.add_argument("--format", choices=("json", "text"), default="text")
    args = parser.parse_args()

    try:
        data = inventory()
        if args.command == "graph":
            result: Any = relationships(data)
        elif args.command == "explain":
            if not args.branch:
                parser.error("explain requires a branch name")
            result = explain(relationships(data), args.branch)
        elif args.command == "status":
            result = {
                "current_branch": data["current_branch"],
                "local_branch_count": sum(b["ref_kind"] == "local" for b in data["branches"]),
                "remote_tracking_branch_count": sum(b["ref_kind"] == "remote_tracking" for b in data["branches"]),
                "default_source_policy": data["default_source_policy"],
                "default_integration_target_policy": data["default_integration_target_policy"],
                "mutations_performed": False,
            }
        else:
            result = data

        if args.format == "json":
            print(json.dumps(result, indent=2, sort_keys=True))
        elif args.command == "status":
            for key, value in result.items():
                print(f"{key}: {value}")
        elif args.command == "explain":
            print(json.dumps(result, indent=2, sort_keys=True))
        else:
            branches = result["branches"]
            for branch in branches:
                upstream = f" -> {branch['upstream']}" if branch.get("upstream") else ""
                current = "*" if branch["is_current"] else " "
                print(f"{current} {branch['ref_kind']:15} {branch['name']}{upstream}")
            if args.command == "graph":
                print("\nRelationships:")
                for edge in result["relationships"]:
                    print(f"  {edge['from']} --[{edge['kind']}]--> {edge['to']}")
    except RuntimeError as exc:
        print(f"branch-manager: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
