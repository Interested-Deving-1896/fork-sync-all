#!/usr/bin/env python3
"""Read-only audit of open PR lifecycle state for GitHub Actions.

Reports evidence from the current PR head SHA. It deliberately does not merge,
change draft state, update branches, or write comments.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any

API = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
REPO = os.environ.get("GITHUB_REPOSITORY", "")
TOKEN = os.environ.get("GITHUB_TOKEN", "")


class ApiError(RuntimeError):
    pass


def api_get(path: str) -> dict[str, Any]:
    request = urllib.request.Request(
        API + path,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {TOKEN}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "fork-sync-all-pr-lifecycle-auditor",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError) as exc:
        raise ApiError(f"GitHub API request failed for {path}: {exc}") from exc


def paginated(path: str, key: str) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    page = 1
    while True:
        separator = "&" if "?" in path else "?"
        payload = api_get(f"{path}{separator}per_page=100&page={page}")
        # GitHub list endpoints may return a bare JSON array or an object.
        batch = payload if isinstance(payload, list) else payload.get(key, [])
        if not isinstance(batch, list):
            raise ApiError(f"Unexpected API response for {path}: missing {key} list")
        items.extend(batch)
        if len(batch) < 100:
            return items
        page += 1


def legacy_status_checks(statuses: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Normalize legacy commit statuses to the check-run shape used by classify."""
    normalized: list[dict[str, Any]] = []
    for item in statuses:
        state = str(item.get("state", "unknown")).lower()
        if state == "pending":
            status, conclusion = "in_progress", None
        elif state == "success":
            status, conclusion = "completed", "success"
        elif state in {"failure", "error"}:
            status, conclusion = "completed", "failure"
        else:
            status, conclusion = "completed", "unknown"
        normalized.append({
            "name": item.get("context", "legacy commit status"),
            "status": status,
            "conclusion": conclusion,
        })
    return normalized


def check_state(checks: list[dict[str, Any]]) -> str:
    if not checks:
        return "unknown"
    active = [c for c in checks if c.get("status") != "completed"]
    if active:
        return "running"
    conclusions = [str(c.get("conclusion") or "unknown") for c in checks]
    if any(x in {"failure", "timed_out", "action_required", "startup_failure"} for x in conclusions):
        return "failed"
    if any(x in {"cancelled", "stale", "unknown", "neutral"} for x in conclusions):
        return "investigate"
    if all(x in {"success", "skipped"} for x in conclusions):
        return "completed"
    return "investigate"


def classify(pr: dict[str, Any], checks: list[dict[str, Any]]) -> tuple[str, str]:
    # A known merge conflict is actionable even while checks are still running.
    merge_state = str(pr.get("mergeable_state") or "").lower()
    if pr.get("mergeable") is False or merge_state in {"dirty", "conflicting"}:
        return "BLOCKED", "GitHub reports merge conflicts; resolve them before review can finish."
    if merge_state in {"blocked", "unstable"}:
        return "BLOCKED", f"GitHub mergeable state is {merge_state}; inspect required checks and branch rules."
    if merge_state == "behind":
        return "STALE", "The branch is behind its base; check whether updating it is appropriate."

    state = check_state(checks)
    if state == "running":
        return "RUNNING", "One or more checks for the current head are queued or in progress."
    if state == "failed":
        return "BLOCKED", "At least one visible check for the current head failed or requires action."
    if state == "investigate":
        return "INVESTIGATE", "A check was cancelled, neutral, stale, or inconclusive."
    if state == "unknown":
        return "UNKNOWN", "No check runs are visible for the current head SHA."
    if pr.get("draft"):
        return "DRAFT — REVIEW STATE NOT SET", "Visible checks completed, but the PR remains a draft; a human must decide whether it is ready for review."
    return "REVIEW REQUIRED", "Visible checks completed; verify required checks, approvals, and branch rules in GitHub."


def audit() -> str:
    if not REPO or not TOKEN:
        raise ApiError("GITHUB_REPOSITORY and GITHUB_TOKEN are required.")
    pulls = paginated(f"/repos/{REPO}/pulls?state=open", "items")
    if not pulls:
        pulls = []
    rows: list[tuple[int, str, str, str]] = []
    counts: dict[str, int] = {}
    for pr in pulls:
        number = pr.get("number")
        head = (pr.get("head") or {}).get("sha", "")
        title = str(pr.get("title", f"PR #{number}")).replace("|", "\\|").replace("\n", " ")
        url = pr.get("html_url", f"https://github.com/{REPO}/pull/{number}")
        if not number or not head:
            status, reason = "UNKNOWN", "Missing PR number or head SHA."
        else:
            try:
                # Check-runs can exceed the API default page size; inspect every page
                # so a later failed or active check cannot be silently missed.
                checks = paginated(f"/repos/{REPO}/commits/{head}/check-runs", "check_runs")
                # Some required workflows still report legacy commit statuses,
                # which are not included in the Check Runs endpoint.
                statuses = paginated(f"/repos/{REPO}/commits/{head}/status", "statuses")
                checks.extend(legacy_status_checks(statuses))
                status, reason = classify(pr, checks)
            except ApiError as exc:
                status, reason = "UNKNOWN", str(exc)
        counts[status] = counts.get(status, 0) + 1
        rows.append((number, f"[#{number} {title}]({url})", status, reason))

    lines = [
        "# Fork-Sync-All PR Lifecycle Audit",
        "",
        f"- Repository: `{REPO}`",
        f"- Open PRs inspected: **{len(rows)}**",
        "- Mode: **read-only** — no merges, branch updates, draft changes, or comments.",
        "- Scope note: check runs are evaluated against each PR's current head SHA.",
        "- A completed set of visible checks is not, by itself, proof that branch protection or approvals are satisfied.",
        "",
        "## Summary",
        "",
    ]
    lines.extend(f"- **{name}:** {count}" for name, count in sorted(counts.items()))
    lines += ["", "## Pull requests", "", "| PR | Status | Evidence / next action |", "|---|---|---|"]
    for _, link, status, reason in rows:
        safe_reason = reason.replace("|", "\\|")
        lines.append(f"| {link} | **{status}** | {safe_reason} |")
    if not rows:
        lines.append("| — | — | No open pull requests found. |")
    lines += ["", "## Interpretation", "",
              "- **RUNNING** means at least one current-head check is not completed.",
              "- **BLOCKED** means a failing check or a reported merge blocker was found.",
              "- **DRAFT — REVIEW STATE NOT SET** means visible checks completed but the PR remains a draft; this auditor will not promote it.",
              "- **REVIEW REQUIRED** is deliberately not labelled merge-ready: required checks, approvals, and repository rules must still be verified.",
              "- **UNKNOWN / INVESTIGATE** means the auditor could not safely infer completion."]
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    try:
        report = audit()
        summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary_path:
            with open(summary_path, "a", encoding="utf-8") as summary:
                summary.write(report)
        print(report)
    except ApiError as exc:
        print(f"PR lifecycle audit incomplete: {exc}", file=sys.stderr)
        sys.exit(2)
