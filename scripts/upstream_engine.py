#!/usr/bin/env python3
"""Report-only upstream lifecycle inventory for explicitly admitted repositories.

The first implementation deliberately performs metadata discovery only. It never
clones, downloads source, changes repository state, creates branches, or opens PRs.
Python 3.10+, standard library only.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Any

API = "https://api.github.com"
USER_AGENT = "fork-sync-all-upstream-engine/0.1"


class UpstreamApiError(RuntimeError):
    pass


def request_json(url: str, token: str | None = None) -> Any:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": USER_AGENT,
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError) as exc:
        status = getattr(exc, "code", "network")
        raise UpstreamApiError(f"GitHub metadata request failed ({status}): {exc}") from exc


def inspect_repository(full_name: str, token: str | None = None) -> dict[str, Any]:
    """Return repository lifecycle and lineage evidence without mutating it."""
    parts = full_name.split("/")
    if len(parts) != 2 or not all(parts):
        raise ValueError(f"repository must be OWNER/NAME: {full_name!r}")
    owner, name = (urllib.parse.quote(part, safe="") for part in parts)
    repo = request_json(f"{API}/repos/{owner}/{name}", token)
    if not isinstance(repo, dict) or not repo.get("full_name"):
        raise UpstreamApiError(f"unexpected repository response for {full_name}")

    parent = repo.get("parent") or {}
    source = repo.get("source") or {}
    lineage = None
    if repo.get("fork"):
        lineage = {
            "relationship": "fork",
            "parent": parent.get("full_name"),
            "canonical_source": source.get("full_name") or parent.get("full_name"),
            "evidence": "GitHub repository parent/source metadata",
        }
    elif repo.get("archived"):
        lineage = {
            "relationship": "unknown",
            "parent": None,
            "canonical_source": None,
            "evidence": "No verified parent/source metadata; manual lineage review required",
        }

    pushed = repo.get("pushed_at")
    age_days = None
    if pushed:
        timestamp = datetime.fromisoformat(pushed.replace("Z", "+00:00"))
        age_days = max(0, (datetime.now(timezone.utc) - timestamp).days)

    return {
        "repository": repo["full_name"],
        "url": repo.get("html_url"),
        "archived": bool(repo.get("archived")),
        "disabled": bool(repo.get("disabled")),
        "fork": bool(repo.get("fork")),
        "default_branch": repo.get("default_branch"),
        "created_at": repo.get("created_at"),
        "pushed_at": pushed,
        "days_since_push": age_days,
        "license": (repo.get("license") or {}).get("spdx_id"),
        "lineage": lineage,
        "assessment": (
            "archived_review_required" if repo.get("archived")
            else "stale_candidate" if age_days is not None and age_days >= 365
            else "recently_active_or_unknown"
        ),
        "limitations": [
            "Source code and dependency manifests have not been inspected",
            "Release compatibility and successor lineage are not verified",
            "No migration or repository changes were attempted",
        ],
    }


def build_report(repositories: list[str], token: str | None = None) -> dict[str, Any]:
    if not repositories:
        raise ValueError("provide at least one explicitly admitted --repo OWNER/NAME")
    records = [inspect_repository(name, token) for name in repositories]
    return {
        "schema_version": 1,
        "engine": "fork-sync-all-upstream-engine",
        "mode": "report-only",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "mutations_performed": False,
        "repositories": records,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", action="append", default=[], help="explicit OWNER/NAME allowlist entry; repeatable")
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    parser.add_argument("--output", help="write report to this path instead of stdout")
    args = parser.parse_args(argv)
    try:
        report = build_report(args.repo, os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN"))
    except (ValueError, UpstreamApiError) as exc:
        print(f"upstream-engine: {exc}", file=sys.stderr)
        return 2

    if args.format == "json":
        rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    else:
        lines = ["# Upstream Engine report", "", f"- Generated: {report['generated_at']}",
                 "- Mode: report-only", "- Repository mutations: none", ""]
        for item in report["repositories"]:
            lines.extend([f"## {item['repository']}", "",
                          f"- Assessment: **{item['assessment']}**",
                          f"- Archived: {item['archived']}",
                          f"- Last push: {item['pushed_at'] or 'unknown'}",
                          f"- Days since push: {item['days_since_push'] if item['days_since_push'] is not None else 'unknown'}",
                          f"- License: {item['license'] or 'unknown'}",
                          f"- Canonical source: {(item.get('lineage') or {}).get('canonical_source') or 'unverified'}", ""])
        rendered = "\\n".join(lines) + "\\n"
    if args.output:
        with open(args.output, "w", encoding="utf-8") as handle:
            handle.write(rendered)
    else:
        sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
