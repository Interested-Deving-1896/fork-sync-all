#!/usr/bin/env python3
"""Inventory open Dependabot alerts and produce an actionable chain-wide backlog."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
SEVERITIES = ("critical", "high", "moderate", "low", "unknown")


class GitHubApiError(RuntimeError):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(f"Dependabot API returned HTTP {status}: {message}")
        self.status = status
        self.message = message


class GitHubDependabotClient:
    """Small REST client for the organization Dependabot alerts endpoint."""

    def __init__(self, token: str, api_url: str = "https://api.github.com") -> None:
        if not token:
            raise ValueError("GH_TOKEN is required to read Dependabot alerts")
        self.api_url = api_url.rstrip("/")
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "fork-sync-all-dependency-risk-audit/1.0",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        self.coverage: dict[str, dict[str, Any]] = {}

    def _page(self, url: str) -> tuple[list[dict[str, Any]], str | None]:
        request = urllib.request.Request(url, headers=self.headers)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                data = json.load(response)
                if not isinstance(data, list):
                    raise RuntimeError(f"unexpected response from {url}")
                return data, _next_link(response.headers.get("Link", ""))
        except urllib.error.HTTPError as exc:
            detail = ""
            try:
                payload = json.loads(exc.read().decode("utf-8", errors="replace"))
                detail = f": {payload.get('message', '')}" if isinstance(payload, dict) else ""
            except (json.JSONDecodeError, OSError):
                pass
            raise GitHubApiError(exc.code, detail.lstrip(": ") or "request failed") from exc

    def _repositories(self, namespace: str) -> list[str]:
        namespace_path = urllib.parse.quote(namespace, safe="")
        url: str | None = (
            f"{self.api_url}/users/{namespace_path}/repos?type=owner&per_page=100"
        )
        names: list[str] = []
        while url:
            page, url = self._page(url)
            names.extend(
                str(item["name"])
                for item in page
                if isinstance(item, dict) and item.get("name")
            )
        return names

    def alerts(
        self,
        namespace: str,
        namespace_kind: str = "organization",
        projects: list[str] | None = None,
    ) -> list[dict[str, Any]]:
        namespace_path = urllib.parse.quote(namespace, safe="")
        if namespace_kind == "user":
            if not projects:
                raise ValueError(
                    f"user namespace {namespace} requires an admitted project list"
                )
            repositories = projects

            def read_repository(repository: str) -> tuple[str, list[dict[str, Any]]]:
                repo_path = urllib.parse.quote(repository, safe="")
                url: str | None = (
                    f"{self.api_url}/repos/{namespace_path}/{repo_path}/dependabot/alerts"
                    "?state=open&per_page=100"
                )
                found: list[dict[str, Any]] = []
                try:
                    while url:
                        page, url = self._page(url)
                        # Unlike the organization aggregate endpoint, GitHub's
                        # per-repository endpoint does not include a repository
                        # object in each alert. Add it here so user-namespace
                        # inventories retain actionable repository attribution.
                        for alert in page:
                            alert.setdefault(
                                "repository",
                                {"full_name": f"{namespace}/{repository}"},
                            )
                        found.extend(page)
                    return "enabled", found
                except GitHubApiError as exc:
                    if "rate limit" in exc.message.casefold():
                        raise
                    if exc.status == 403 and "alerts are disabled" in exc.message.casefold():
                        return "disabled", []
                    if exc.status not in {403, 404}:
                        raise
                    return "unavailable", []

            alerts: list[dict[str, Any]] = []
            states: Counter[str] = Counter()
            with ThreadPoolExecutor(max_workers=12) as executor:
                for state, found in executor.map(read_repository, repositories):
                    states[state] += 1
                    alerts.extend(found)
            if not states["enabled"] and not states["disabled"]:
                raise RuntimeError(
                    f"cannot read Dependabot alerts for any project in user namespace {namespace}"
                )
            self.coverage[namespace] = {
                "mode": "admitted-projects",
                "projects": len(repositories),
                "enabled": states["enabled"],
                "disabled": states["disabled"],
                "unavailable": states["unavailable"],
            }
            return alerts
        if namespace_kind != "organization":
            raise ValueError(f"unsupported namespace kind: {namespace_kind}")
        url: str | None = (
            f"{self.api_url}/orgs/{namespace_path}/dependabot/alerts"
            "?state=open&per_page=100"
        )
        alerts: list[dict[str, Any]] = []
        while url:
            page, url = self._page(url)
            alerts.extend(page)
        self.coverage[namespace] = {"mode": "organization-aggregate"}
        return alerts


def _next_link(value: str) -> str | None:
    for item in value.split(","):
        parts = [part.strip() for part in item.split(";")]
        if len(parts) > 1 and 'rel="next"' in parts[1:]:
            return parts[0].strip("<>")
    return None


def _text(value: Any, fallback: str = "unknown") -> str:
    return str(value).strip() if value not in (None, "") else fallback


def normalize_alert(namespace: str, alert: dict[str, Any]) -> dict[str, Any]:
    advisory = alert.get("security_advisory") or {}
    dependency = alert.get("dependency") or {}
    package = dependency.get("package") or {}
    repository = alert.get("repository") or {}
    severity = _text(advisory.get("severity")).lower()
    severity = {"medium": "moderate"}.get(severity, severity)
    if severity not in SEVERITIES:
        severity = "unknown"
    patched = (alert.get("security_vulnerability") or {}).get(
        "first_patched_version"
    ) or {}
    return {
        "namespace": namespace,
        "repository": _text(repository.get("full_name")),
        "number": alert.get("number"),
        "severity": severity,
        "package": _text(package.get("name")),
        "ecosystem": _text(package.get("ecosystem")),
        "manifest": _text(dependency.get("manifest_path")),
        "patched_version": patched.get("identifier") or None,
        "summary": _text(advisory.get("summary")),
        "created_at": alert.get("created_at"),
        "url": alert.get("html_url") or "",
    }


def audit(policy: dict[str, Any], client: Any) -> dict[str, Any]:
    if policy.get("schema_version") != 1:
        raise ValueError("dependency risk policy schema_version must be 1")
    namespaces = policy.get("namespaces")
    if not isinstance(namespaces, list) or not namespaces or not all(
        isinstance(value, str) and value.strip() for value in namespaces
    ):
        raise ValueError("dependency risk policy namespaces must be a non-empty string list")
    exceptions = policy.get("repository_exceptions", {})
    if not isinstance(exceptions, dict):
        raise ValueError("repository_exceptions must be an object")
    for repository, reason in exceptions.items():
        if not isinstance(repository, str) or not isinstance(reason, str):
            raise ValueError("repository exceptions must map project slugs to reasons")
        if "owner=" not in reason or "expires=" not in reason:
            raise ValueError(
                f"exception for {repository} must include owner= and expires=YYYY-MM-DD"
            )
        expiry_text = reason.split("expires=", 1)[1].split(";", 1)[0].strip()
        try:
            expiry = date.fromisoformat(expiry_text)
        except ValueError as exc:
            raise ValueError(f"exception for {repository} has invalid expiry") from exc
        if expiry < date.today():
            raise ValueError(f"exception for {repository} expired on {expiry_text}")

    namespace_kinds = policy.get("namespace_kinds", {})
    if not isinstance(namespace_kinds, dict):
        raise ValueError("namespace_kinds must be an object")
    for namespace in namespaces:
        if namespace_kinds.get(namespace, "organization") not in {
            "organization",
            "user",
        }:
            raise ValueError(f"unsupported namespace kind for {namespace}")

    records: list[dict[str, Any]] = []
    inventory: dict[str, int] = {}
    coverage: dict[str, dict[str, Any]] = {}
    for namespace in namespaces:
        kind = namespace_kinds.get(namespace, "organization")
        found = [
            normalize_alert(namespace, item)
            for item in client.alerts(
                namespace,
                kind,
                policy.get("_project_names") if kind == "user" else None,
            )
        ]
        inventory[namespace] = len(found)
        client_coverage = getattr(client, "coverage", {})
        if namespace in client_coverage:
            coverage[namespace] = client_coverage[namespace]
        records.extend(found)

    active = [item for item in records if item["repository"] not in exceptions]
    exempt = [item for item in records if item["repository"] in exceptions]
    order = {severity: position for position, severity in enumerate(SEVERITIES)}
    active.sort(key=lambda item: (order[item["severity"]], item["repository"], item["package"]))
    severity_counts = Counter(item["severity"] for item in active)
    repository_counts: dict[str, Counter[str]] = defaultdict(Counter)
    for item in active:
        repository_counts[item["repository"]][item["severity"]] += 1
    fail_on = set(policy.get("fail_on_severities", ["critical"]))
    invalid_severities = fail_on.difference(SEVERITIES)
    if invalid_severities:
        raise ValueError(
            "unknown fail_on_severities: " + ", ".join(sorted(invalid_severities))
        )
    blocking = sum(severity_counts[value] for value in fail_on if value in SEVERITIES)
    return {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "healthy": blocking == 0,
        "blocking_alerts": blocking,
        "fail_on_severities": sorted(fail_on),
        "inventory": inventory,
        "coverage": coverage,
        "counts": {severity: severity_counts[severity] for severity in SEVERITIES},
        "repository_counts": {
            repository: {severity: counts[severity] for severity in SEVERITIES}
            for repository, counts in sorted(repository_counts.items())
        },
        "alerts": active,
        "exempt_alerts": exempt,
        "exceptions": exceptions,
    }


def _cell(value: Any) -> str:
    return _text(value, "").replace("|", "\\|").replace("\n", " ")


def render_markdown(report: dict[str, Any], report_limit: int = 100) -> str:
    counts = report["counts"]
    lines = [
        "# Dependency vulnerability backlog",
        "",
        f"**Gate:** {'Passing' if report['healthy'] else 'Blocked by critical risk'}",
        "",
        f"Generated: `{report['generated_at']}`",
        "",
        f"Open alerts: **{sum(counts.values())}** — "
        + ", ".join(f"{severity}: **{counts[severity]}**" for severity in SEVERITIES),
        "",
        "| Namespace | Open alerts | Coverage |",
        "|---|---:|---|",
    ]
    for namespace, alert_count in report["inventory"].items():
        details = report.get("coverage", {}).get(namespace, {})
        if details.get("mode") == "admitted-projects":
            coverage = (
                f"{details['enabled']} enabled, {details['disabled']} disabled, "
                f"{details['unavailable']} unavailable of {details['projects']} admitted"
            )
        else:
            coverage = "organization aggregate"
        lines.append(f"| {_cell(namespace)} | {alert_count} | {coverage} |")
    lines.extend(
        [
        "",
        "## Repository priority",
        "",
        "| Repository | Critical | High | Moderate | Low | Unknown |",
        "|---|---:|---:|---:|---:|---:|",
        ]
    )
    for repository, values in report["repository_counts"].items():
        lines.append(
            f"| {_cell(repository)} | {values['critical']} | {values['high']} | "
            f"{values['moderate']} | {values['low']} | {values['unknown']} |"
        )
    if not report["repository_counts"]:
        lines.append("| _No open alerts_ | 0 | 0 | 0 | 0 | 0 |")

    lines.extend(
        [
            "",
            "## Prioritized alerts",
            "",
            "| Severity | Repository | Dependency | Patched version | Advisory |",
            "|---|---|---|---|---|",
        ]
    )
    for alert in report["alerts"][: max(0, report_limit)]:
        summary = _cell(alert["summary"])
        if alert["url"]:
            summary = f"[{summary}]({alert['url']})"
        lines.append(
            f"| {alert['severity']} | {_cell(alert['repository'])} | "
            f"{_cell(alert['ecosystem'])}: `{_cell(alert['package'])}` | "
            f"{_cell(alert['patched_version'] or 'not published')} | {summary} |"
        )
    omitted = len(report["alerts"]) - min(len(report["alerts"]), max(0, report_limit))
    if omitted:
        lines.append(f"\n_{omitted} additional alerts are available in the JSON artifact._")
    if report["exceptions"]:
        lines.extend(["", "## Documented exceptions", ""])
        lines.extend(
            f"- **{repository}** — {_cell(reason)}"
            for repository, reason in sorted(report["exceptions"].items())
        )
    lines.extend(
        [
            "",
            "## Triage order",
            "",
            "1. Merge or prepare fixes for critical alerts with a published patched version.",
            "2. Isolate or replace dependencies whose critical advisory has no patch.",
            "3. Work high-severity repositories from largest backlog to smallest.",
            "4. Record temporary exceptions in the policy with an owner and expiry in the reason.",
            "",
        ]
    )
    return "\n".join(lines)


def write_outputs(paths: Iterable[tuple[Path, str]]) -> None:
    for path, content in paths:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--policy", type=Path, default=ROOT / "config" / "dependency-risk-policy.json"
    )
    parser.add_argument("--output-json", type=Path, required=True)
    parser.add_argument("--output-markdown", type=Path, required=True)
    parser.add_argument("--fail-on-policy", action="store_true")
    args = parser.parse_args()
    try:
        policy = json.loads(args.policy.read_text(encoding="utf-8"))
        project_manifest = policy.get("project_manifest")
        if project_manifest:
            manifest_path = Path(project_manifest)
            if not manifest_path.is_absolute():
                manifest_path = ROOT / manifest_path
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            projects = manifest.get("projects", [])
            policy["_project_names"] = [
                item["name"]
                for item in projects
                if isinstance(item, dict) and isinstance(item.get("name"), str)
            ]
        report = audit(policy, GitHubDependabotClient(os.environ.get("GH_TOKEN", "")))
        markdown = render_markdown(report, int(policy.get("report_limit", 100)))
        write_outputs(
            (
                (args.output_json, json.dumps(report, indent=2, sort_keys=True) + "\n"),
                (args.output_markdown, markdown),
            )
        )
        print(markdown)
        return 1 if args.fail_on_policy and not report["healthy"] else 0
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"audit-dependency-risk: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
