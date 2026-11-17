#!/usr/bin/env python3
"""Fail-closed, non-destructive GitHub OSP -> OOC mirror updater.

Dry-run is the default. Writes require --write plus three independent
workflow/environment approvals. Branches are fast-forward-only; tags are
create-only. Target-only refs are never deleted.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from typing import Callable

REMOTE_URL = "https://github.com/OpenOS-Project-Ecosystem-OOC/lkm.git"
EXPECTED_SOURCE = "OpenOS-Project-OSP/lkm"


class MirrorError(RuntimeError):
    pass


def run_git(*args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *args], text=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, check=False,
    )
    if check and result.returncode:
        raise MirrorError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout.strip()


def plan_refs(
    source_branches: dict[str, str],
    target_branches: dict[str, str],
    source_tags: dict[str, str],
    target_tags: dict[str, str],
    is_ancestor: Callable[[str, str], bool],
) -> list[dict[str, str]]:
    """Build a complete plan without modifying any remote refs."""
    plan: list[dict[str, str]] = []
    for name, source_sha in sorted(source_branches.items()):
        target_sha = target_branches.get(name)
        if target_sha is None:
            action = "create"
        elif target_sha == source_sha:
            action = "unchanged"
        elif is_ancestor(target_sha, source_sha):
            action = "fast_forward"
        elif is_ancestor(source_sha, target_sha):
            action = "target_ahead_preserve"
        else:
            action = "blocked_divergence"
        plan.append({
            "ref": f"refs/heads/{name}", "source_sha": source_sha,
            "target_sha": target_sha or "", "action": action,
        })

    for name, source_sha in sorted(source_tags.items()):
        target_sha = target_tags.get(name)
        action = "create" if target_sha is None else (
            "unchanged" if target_sha == source_sha else "blocked_tag_conflict"
        )
        plan.append({
            "ref": f"refs/tags/{name}", "source_sha": source_sha,
            "target_sha": target_sha or "", "action": action,
        })
    return plan


def ref_map(prefix: str) -> dict[str, str]:
    output = run_git(
        "for-each-ref", "--format=%(refname) %(objectname)", prefix
    )
    refs: dict[str, str] = {}
    for line in output.splitlines():
        ref, sha = line.split()
        refs[ref.removeprefix(prefix + "/")] = sha
    return refs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true",
                        help="perform writes after complete preflight")
    args = parser.parse_args()

    try:
        if os.environ.get("GITHUB_REPOSITORY") != EXPECTED_SOURCE:
            raise MirrorError(
                f"must run from {EXPECTED_SOURCE}; refusing this repository"
            )

        if args.write:
            required = {
                "GITHUB_EVENT_NAME": "workflow_dispatch",
                "MIRROR_WRITE_ENABLED": "true",
                "MIRROR_WRITE_APPROVED": "true",
            }
            for key, expected in required.items():
                if os.environ.get(key) != expected:
                    raise MirrorError(f"write gate not satisfied: {key}")
            if not os.environ.get("MIRROR_TOKEN"):
                raise MirrorError("MIRROR_TOKEN is required for an approved write")

        token = os.environ.get("MIRROR_TOKEN", "")
        if token:
            import base64
            auth = base64.b64encode(f"x-access-token:{token}".encode()).decode()
            os.environ["GIT_CONFIG_COUNT"] = "1"
            os.environ["GIT_CONFIG_KEY_0"] = "http.extraheader"
            os.environ["GIT_CONFIG_VALUE_0"] = f"AUTHORIZATION: basic {auth}"

        run_git("fetch", "--no-tags", REMOTE_URL,
                "+refs/heads/*:refs/mirror-preflight/heads/*")
        run_git("fetch", "--no-tags", REMOTE_URL,
                "+refs/tags/*:refs/mirror-preflight/tags/*")

        source_branches = ref_map("refs/heads")
        target_branches = ref_map("refs/mirror-preflight/heads")
        source_tags = ref_map("refs/tags")
        target_tags = ref_map("refs/mirror-preflight/tags")

        def ancestor(old: str, new: str) -> bool:
            return subprocess.run(
                ["git", "merge-base", "--is-ancestor", old, new],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                check=False,
            ).returncode == 0

        plan = plan_refs(source_branches, target_branches, source_tags,
                         target_tags, ancestor)
        blocked = [row for row in plan if row["action"].startswith("blocked_")]
        actionable = [row for row in plan
                      if row["action"] in ("create", "fast_forward")]

        result = {
            "source": EXPECTED_SOURCE,
            "target": "OpenOS-Project-Ecosystem-OOC/lkm",
            "mode": "write" if args.write else "dry_run",
            "deletions": 0,
            "force_updates": 0,
            "blocked_count": len(blocked),
            "planned_count": len(actionable),
            "refs": plan,
        }
        if blocked:
            print(json.dumps(result, sort_keys=True))
            return 2

        # Verify every proposed refspec with a dry-run before the first write.
        for row in actionable:
            ref = row["ref"]
            source_ref = ref
            run_git("push", "--dry-run", REMOTE_URL,
                    f"{source_ref}:{ref}")

        if args.write:
            for row in actionable:
                ref = row["ref"]
                run_git("push", REMOTE_URL, f"{ref}:{ref}")
            result["mode"] = "written"
        print(json.dumps(result, sort_keys=True))
        return 0
    except MirrorError as exc:
        print(json.dumps({"error": str(exc), "mode": "aborted"}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
