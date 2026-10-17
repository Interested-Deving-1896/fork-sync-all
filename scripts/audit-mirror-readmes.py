#!/usr/bin/env python3
"""Audit live GitHub mirror-chain README surfaces against a neutral baseline."""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from live_chain_manifest import ManifestError, load_manifest, project_index


ROOT = Path(__file__).resolve().parents[1]


class GitHubClient:
    def __init__(self, token: str = "") -> None:
        self.headers = {
            "Accept": "application/vnd.github+json",
            "User-Agent": "fork-sync-all-mirror-readme-audit/1.0",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        if token:
            self.headers["Authorization"] = f"Bearer {token}"

    def get(self, path: str) -> tuple[int, Any]:
        request = urllib.request.Request(
            f"https://api.github.com/{path.lstrip('/')}", headers=self.headers
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as exc:
            return exc.code, None

    def repositories(self, owner: str) -> list[dict[str, Any]]:
        code, data = self.get(f"orgs/{owner}/repos?per_page=100&type=all")
        if code != 200 or not isinstance(data, list):
            raise RuntimeError(f"cannot list {owner} repositories (HTTP {code})")
        return data

    def repository(self, owner: str, name: str) -> dict[str, Any] | None:
        code, data = self.get(f"repos/{owner}/{name}")
        return data if code == 200 and isinstance(data, dict) else None

    def readme(self, owner: str, name: str) -> str | None:
        code, data = self.get(f"repos/{owner}/{name}/readme")
        if code != 200 or not isinstance(data, dict):
            return None
        try:
            return base64.b64decode(data.get("content", "")).decode(
                "utf-8", errors="replace"
            )
        except (ValueError, TypeError):
            return None


def baseline_findings(content: str | None, policy: dict[str, Any]) -> list[str]:
    if content is None:
        return ["README.md is missing"]
    findings: list[str] = []
    visible_lines: list[str] = []
    fence: tuple[str, int] | None = None
    for line in content.splitlines():
        marker = re.match(r"^\s*(`{3,}|~{3,})", line)
        if marker:
            value = marker.group(1)
            if fence is None:
                fence = (value[0], len(value))
            elif value[0] == fence[0] and len(value) >= fence[1]:
                fence = None
            continue
        if fence is None:
            visible_lines.append(line)
    visible = "\n".join(visible_lines)
    h1_count = len(re.findall(r"^#\s+\S", visible, re.M))
    if h1_count != 1:
        findings.append(f"expected one H1; found {h1_count}")
    for heading in policy["required_headings"]:
        if not re.search(rf"^##\s+{re.escape(heading)}\s*$", visible, re.I | re.M):
            findings.append(f"missing heading: {heading}")
    for section in policy["required_managed_sections"]:
        start = f"<!-- AI:start:{section} -->"
        end = f"<!-- AI:end:{section} -->"
        if start not in content or end not in content:
            findings.append(f"missing or unbalanced managed section: {section}")
    if policy["required_badge_text"] not in content:
        findings.append("missing required project badge")
    for forbidden, description in policy.get("forbidden_text", {}).items():
        if forbidden in content:
            findings.append(f"{description}: {forbidden}")
    return findings


def audit(
    policy: dict[str, Any], manifest: dict[str, Any], client: GitHubClient
) -> dict[str, Any]:
    source = manifest["source"]
    mirrors = manifest["mirrors"]
    if source["platform"] != "github" or any(
        mirror["platform"] != "github" for mirror in mirrors
    ):
        raise ValueError(
            "mirror README audit currently requires GitHub source and mirror coordinates"
        )
    source_owner = source["namespace"]
    mirror_owners = [mirror["namespace"] for mirror in mirrors]
    inventories = {owner: client.repositories(owner) for owner in mirror_owners}
    admissions = project_index(manifest)
    live_names = {
        repository["name"]
        for repositories in inventories.values()
        for repository in repositories
    }
    names = sorted(live_names | set(admissions))
    live = {
        owner: {repository["name"]: repository for repository in repositories}
        for owner, repositories in inventories.items()
    }

    def inspect(name: str) -> dict[str, Any]:
        admission = admissions.get(name)
        row: dict[str, Any] = {
            "name": name,
            "classification": (
                admission["readme_policy"] if admission else "unapproved"
            ),
            "repositories": {},
            "findings": [],
        }
        if admission and admission["readme_policy"] == "exception":
            row["exception_reason"] = admission["reason"]
        if admission is None:
            row["findings"].append(
                "unapproved live project; add it to config/live-chain-manifest.json "
                "before admitting it to the chain"
            )
        source_meta = client.repository(source_owner, name)
        owners = [source_owner, *mirror_owners]
        contents: dict[str, str | None] = {}
        for owner in owners:
            exists = source_meta is not None if owner == source_owner else name in live[owner]
            content = client.readme(owner, name) if exists else None
            contents[owner] = content
            row["repositories"][owner] = {
                "exists": exists,
                "readme": content is not None,
                "bytes": len(content.encode("utf-8")) if content is not None else 0,
            }
        if row["classification"] in {"exception", "unapproved"}:
            return row
        if source_meta is None:
            row["findings"].append(f"missing canonical source: {source_owner}/{name}")
            return row
        for finding in baseline_findings(contents[source_owner], policy):
            row["findings"].append(f"{source_owner}: {finding}")
        source_content = contents[source_owner]
        for owner in mirror_owners:
            if name not in live[owner]:
                row["findings"].append(f"missing mirror repository: {owner}/{name}")
                continue
            for finding in baseline_findings(contents[owner], policy):
                row["findings"].append(f"{owner}: {finding}")
            if source_content is not None and contents[owner] != source_content:
                row["findings"].append(f"README drift: {source_owner} -> {owner}")
        return row

    with ThreadPoolExecutor(max_workers=12) as executor:
        projects = list(executor.map(inspect, names))
    findings = [
        {"project": project["name"], "finding": finding}
        for project in projects
        for finding in project["findings"]
    ]
    return {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "healthy": not findings,
        "inventory": {
            owner: len(repositories) for owner, repositories in inventories.items()
        },
        "admission": {
            "approved": len(admissions),
            "unapproved_live": len(live_names - set(admissions)),
        },
        "projects": projects,
        "findings": findings,
    }


def render_markdown(report: dict[str, Any]) -> str:
    managed = [p for p in report["projects"] if p["classification"] == "managed"]
    exceptions = [p for p in report["projects"] if p["classification"] == "exception"]
    unapproved = [p for p in report["projects"] if p["classification"] == "unapproved"]
    lines = [
        "# Mirror-chain README audit",
        "",
        f"**Overall:** {'Healthy' if report['healthy'] else 'Attention required'}",
        "",
        f"Generated: `{report['generated_at']}`",
        "",
        f"Managed projects: **{len(managed)}**  ",
        f"Documented exceptions: **{len(exceptions)}**  ",
        f"Unapproved live projects: **{len(unapproved)}**  ",
        f"Findings: **{len(report['findings'])}**",
        "",
        "| Mirror namespace | Repositories |",
        "|---|---:|",
    ]
    lines.extend(f"| {owner} | {count} |" for owner, count in report["inventory"].items())
    lines.extend(["", "## Findings", ""])
    if report["findings"]:
        lines.extend(
            f"- **{item['project']}** — {item['finding']}" for item in report["findings"]
        )
    else:
        lines.append("No README baseline or mirror drift findings.")
    lines.extend(["", "## Documented exceptions", ""])
    lines.extend(
        f"- **{project['name']}** — {project['exception_reason']}"
        for project in exceptions
    )
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--policy", type=Path, default=ROOT / "config" / "mirror-readme-baseline.json"
    )
    parser.add_argument(
        "--manifest", type=Path, default=ROOT / "config" / "live-chain-manifest.json"
    )
    parser.add_argument("--output-json", type=Path, required=True)
    parser.add_argument("--output-markdown", type=Path, required=True)
    parser.add_argument("--fail-on-findings", action="store_true")
    args = parser.parse_args()
    try:
        policy = json.loads(args.policy.read_text(encoding="utf-8"))
        if policy.get("schema_version") != 1:
            raise ValueError("mirror README policy schema_version must be 1")
        manifest = load_manifest(args.manifest)
        report = audit(
            policy, manifest, GitHubClient(os.environ.get("GH_TOKEN", ""))
        )
        args.output_json.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        args.output_markdown.write_text(render_markdown(report), encoding="utf-8")
        print(render_markdown(report))
        return 1 if args.fail_on_findings and not report["healthy"] else 0
    except (
        OSError,
        ValueError,
        RuntimeError,
        ManifestError,
        json.JSONDecodeError,
    ) as exc:
        print(f"audit-mirror-readmes: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
