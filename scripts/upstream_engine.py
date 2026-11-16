#!/usr/bin/env python3
"""Read-only upstream lifecycle and organization discovery for Fork-Sync-All.

The engine performs GitHub metadata discovery only. It never clones, downloads
source, changes repository state, creates branches, or opens pull requests.
Python 3.10+, standard library only.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Any

API = "https://api.github.com"
USER_AGENT = "fork-sync-all-upstream-engine/0.2"
CATEGORIES = ("edge", "kubernetes", "iac", "sdk-cli", "ai", "docs-samples", "other")


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


def list_organization_repositories(organization: str, token: str | None = None) -> list[dict[str, Any]]:
    """List all public organization repositories, following REST pagination."""
    if not re.fullmatch(r"[A-Za-z0-9-]{1,39}", organization):
        raise ValueError(f"invalid GitHub organization name: {organization!r}")
    records: list[dict[str, Any]] = []
    page = 1
    while True:
        query = urllib.parse.urlencode({
            "type": "public", "per_page": 100, "page": page,
            "sort": "full_name", "direction": "asc",
        })
        payload = request_json(f"{API}/orgs/{urllib.parse.quote(organization, safe='')}/repos?{query}", token)
        if not isinstance(payload, list):
            raise UpstreamApiError(f"unexpected repository list response for organization {organization}")
        if any(not isinstance(item, dict) for item in payload):
            raise UpstreamApiError(f"invalid repository item in organization {organization} response")
        records.extend(payload)
        if len(payload) < 100:
            break
        page += 1
    return sorted(records, key=lambda item: str(item.get("full_name", "")).casefold())


def classify_repository(repo: dict[str, Any]) -> str:
    """Apply deterministic keyword classification to repository metadata."""
    text = " ".join(str(value) for value in (
        repo.get("name"), repo.get("description"), repo.get("language"),
        " ".join(repo.get("topics") or []),
    ) if value).casefold()
    rules = (
        ("edge", r"edgeworkers?|edgekv|edge compute|edge runtime"),
        ("kubernetes", r"kubernetes|\bk8s\b|lke|cluster api|csi driver"),
        ("iac", r"terraform|ansible|packer|pulumi|infrastructure as code"),
        ("sdk-cli", r"\bsdk\b|api client|client.{0,40}api|api.{0,40}client|\bcli\b|openapi|api bindings"),
        ("ai", r"\bai\b|inference|\bllm\b|machine learning"),
        ("docs-samples", r"\bdocs?\b|documentation|tutorial|workshop|example|sample"),
    )
    for category, pattern in rules:
        if re.search(pattern, text):
            return category
    return "other"


def _assessment(repo: dict[str, Any]) -> tuple[str | None, int | None, str]:
    pushed = repo.get("pushed_at")
    age_days = None
    if pushed:
        timestamp = datetime.fromisoformat(pushed.replace("Z", "+00:00"))
        age_days = max(0, (datetime.now(timezone.utc) - timestamp).days)
    if repo.get("archived"):
        assessment = "archived_review_required"
    elif age_days is not None and age_days >= 365:
        assessment = "stale_candidate"
    else:
        assessment = "recently_active_or_unknown"
    return pushed, age_days, assessment


def _normalize_repository(repo: dict[str, Any], organization: str | None = None) -> dict[str, Any]:
    full_name = repo.get("full_name")
    if not isinstance(full_name, str) or "/" not in full_name:
        raise UpstreamApiError("repository metadata is missing a valid full_name")
    pushed, age_days, assessment = _assessment(repo)
    archived = bool(repo.get("archived"))
    return {
        "repository": full_name,
        "organization": organization or full_name.split("/", 1)[0],
        "url": repo.get("html_url"),
        "description": repo.get("description"),
        "visibility": repo.get("visibility", "public"),
        "archived": archived,
        "disabled": bool(repo.get("disabled")),
        "fork": bool(repo.get("fork")),
        "default_branch": repo.get("default_branch"),
        "language": repo.get("language"),
        "topics": sorted(repo.get("topics") or []),
        "created_at": repo.get("created_at"),
        "pushed_at": pushed,
        "days_since_push": age_days,
        "license": (repo.get("license") or {}).get("spdx_id"),
        "category": classify_repository(repo),
        "candidate": not archived and not bool(repo.get("disabled")),
        "assessment": assessment,
    }


def inspect_repository(full_name: str, token: str | None = None) -> dict[str, Any]:
    """Return repository lifecycle and lineage evidence without mutating it."""
    parts = full_name.split("/")
    if len(parts) != 2 or not all(parts):
        raise ValueError(f"repository must be OWNER/NAME: {full_name!r}")
    owner, name = (urllib.parse.quote(part, safe="") for part in parts)
    repo = request_json(f"{API}/repos/{owner}/{name}", token)
    if not isinstance(repo, dict) or not repo.get("full_name"):
        raise UpstreamApiError(f"unexpected repository response for {full_name}")

    record = _normalize_repository(repo)
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
    record["lineage"] = lineage
    record["limitations"] = [
        "Source code and dependency manifests have not been inspected",
        "Release compatibility and successor lineage are not verified",
        "No migration or repository changes were attempted",
    ]
    return record


def build_report(
    repositories: list[str] | None = None,
    organizations: list[str] | None = None,
    token: str | None = None,
    allowlist: list[str] | None = None,
    denylist: list[str] | None = None,
    categories: list[str] | None = None,
) -> dict[str, Any]:
    repositories = repositories or []
    organizations = organizations or []
    if not repositories and not organizations:
        raise ValueError("provide at least one --repo OWNER/NAME or --org ORGANIZATION")

    records: list[dict[str, Any]] = []
    for organization in sorted(set(organizations), key=str.casefold):
        records.extend(
            _normalize_repository(item, organization)
            for item in list_organization_repositories(organization, token)
        )
    records.extend(inspect_repository(name, token) for name in repositories)

    allow = {name.casefold() for name in (allowlist or [])}
    deny = {name.casefold() for name in (denylist or [])}
    wanted_categories = set(categories or [])
    if wanted_categories - set(CATEGORIES):
        raise ValueError(f"unknown category: {sorted(wanted_categories - set(CATEGORIES))[0]}")
    unique: dict[str, dict[str, Any]] = {}
    for record in records:
        name = record["repository"]
        if allow and name.casefold() not in allow:
            continue
        if name.casefold() in deny:
            continue
        if wanted_categories and record["category"] not in wanted_categories:
            continue
        unique[name.casefold()] = record
    records = sorted(unique.values(), key=lambda item: item["repository"].casefold())
    return {
        "schema_version": 2,
        "engine": "fork-sync-all-upstream-engine",
        "mode": "report-only",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "mutations_performed": False,
        "discovery": {
            "organizations": sorted(set(organizations), key=str.casefold),
            "explicit_repositories": sorted(set(repositories), key=str.casefold),
            "allowlist": sorted(allow),
            "denylist": sorted(deny),
            "categories": sorted(wanted_categories),
            "public_only": bool(organizations),
            "archived_policy": "included_in_inventory_but_not_candidates",
        },
        "summary": {
            "repository_count": len(records),
            "candidate_count": sum(1 for item in records if item["candidate"]),
            "archived_count": sum(1 for item in records if item["archived"]),
        },
        "repositories": records,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", action="append", default=[], help="explicit OWNER/NAME repository; repeatable")
    parser.add_argument("--org", action="append", default=[], help="discover all public repositories in an organization; repeatable")
    parser.add_argument("--allow", action="append", default=[], help="include only this exact OWNER/NAME; repeatable")
    parser.add_argument("--deny", action="append", default=[], help="exclude this exact OWNER/NAME; repeatable")
    parser.add_argument("--category", action="append", choices=CATEGORIES, default=[], help="include this category; repeatable")
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    parser.add_argument("--output", help="write report to this path instead of stdout")
    args = parser.parse_args(argv)
    try:
        report = build_report(args.repo, args.org,
                              os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN"),
                              args.allow, args.deny, args.category)
    except (ValueError, UpstreamApiError) as exc:
        print(f"upstream-engine: {exc}", file=sys.stderr)
        return 2

    if args.format == "json":
        rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    else:
        lines = [
            "# Upstream Engine report", "",
            f"- Generated: {report['generated_at']}",
            "- Mode: report-only",
            "- Repository mutations: none",
            f"- Organizations: {', '.join(report['discovery']['organizations']) or 'none'}",
            f"- Repositories: {report['summary']['repository_count']}",
            f"- Candidates (not archived/disabled): {report['summary']['candidate_count']}",
            f"- Archived (reported, not candidates): {report['summary']['archived_count']}", "",
        ]
        for item in report["repositories"]:
            lines.extend([
                f"## {item['repository']}", "",
                f"- Category: {item['category']}",
                f"- Candidate: {item['candidate']}",
                f"- Assessment: **{item['assessment']}**",
                f"- Archived: {item['archived']}",
                f"- Description: {item['description'] or 'unknown'}",
                f"- Default branch: {item['default_branch'] or 'unknown'}",
                f"- Last push: {item['pushed_at'] or 'unknown'}",
                f"- License: {item['license'] or 'unknown'}", "",
            ])
        rendered = "\n".join(lines) + "\n"
    if args.output:
        with open(args.output, "w", encoding="utf-8") as handle:
            handle.write(rendered)
    else:
        sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
