#!/usr/bin/env python3
"""Report-only PR evidence assessment using trusted base-branch code.

Evidence is transported in a marked PR issue comment so the evidence can
reference the exact PR head SHA without changing that commit. This helper
never changes PR state or grants approval/merge authority.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

MARKER = "<!-- fsa-agent-evidence:v1 -->"
MAX_EVIDENCE_BYTES = 262144
FENCE_RE = re.compile(r"```(?:json)?\s*(.*?)\s*```", re.IGNORECASE | re.DOTALL)


def extract_evidence_comment(comments: list[dict]) -> tuple[bytes, dict] | None:
    """Return the newest marked evidence comment and its GitHub metadata."""
    for comment in comments:
        body = comment.get("body", "")
        if not isinstance(body, str) or MARKER not in body:
            continue
        match = FENCE_RE.search(body.split(MARKER, 1)[1])
        if not match:
            raise ValueError("marked evidence comment has no fenced JSON payload")
        payload = match.group(1).strip().encode("utf-8")
        if len(payload) > MAX_EVIDENCE_BYTES:
            raise ValueError("evidence artifact exceeds the 256 KiB limit")
        json.loads(payload.decode("utf-8"))
        return payload, {
            "comment_id": comment.get("id"),
            "author": (comment.get("user") or {}).get("login", "unknown"),
            "created_at": comment.get("created_at", "unknown"),
            "url": comment.get("html_url", ""),
        }
    return None


def validate_target_binding(evidence_bytes: bytes, repo: str, number: str, head_sha: str) -> None:
    """Require evidence to identify the actual PR event target exactly."""
    evidence = json.loads(evidence_bytes.decode("utf-8"))
    if not isinstance(evidence, dict):
        raise ValueError("evidence must be a JSON object")
    pr = evidence.get("pull_request")
    if evidence.get("repository") != repo:
        raise ValueError("evidence repository does not match the current PR repository")
    if not isinstance(pr, dict) or pr.get("number") != int(number):
        raise ValueError("evidence pull request number does not match the current PR")
    if pr.get("head_sha") != head_sha:
        raise ValueError("evidence head SHA does not match the current PR head SHA")


def append_summary(message: str) -> None:
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as summary:
            summary.write(message.rstrip() + "\n")


def main() -> int:
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    number = os.environ.get("PR_NUMBER", "")
    head_sha = os.environ.get("PR_HEAD_SHA", "")
    token = os.environ.get("GITHUB_TOKEN", "")
    api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    validator = Path("scripts/validate-agent-evidence.py")
    policy = Path("config/agent-accountability-policy.yml")

    if not validator.is_file() or not policy.is_file():
        append_summary("### Agent evidence assessment\nThe trusted base branch does not yet contain the evidence evaluator; report-only assessment is unavailable.")
        return 0
    if not (repo and number.isdigit() and head_sha and token):
        append_summary("### Agent evidence assessment\nRequired PR metadata or read-only token is unavailable; no evidence conclusion was made.")
        return 0

    url = f"{api_url}/repos/{repo}/issues/{number}/comments?per_page=100&sort=created&direction=desc"
    request = Request(url, headers={
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "fork-sync-all-agent-evidence-report",
    })

    try:
        with urlopen(request, timeout=15) as response:
            raw_comments = response.read(2_000_001)
        if len(raw_comments) > 2_000_000:
            raise ValueError("PR comment response exceeds the 2 MB safety limit")
        comments = json.loads(raw_comments.decode("utf-8"))
        if not isinstance(comments, list):
            raise ValueError("GitHub comments response is not an array")
    except HTTPError as exc:
        append_summary(f"### Agent evidence assessment\nGitHub API returned HTTP {exc.code}; assessment unavailable (report-only).")
        return 0
    except (URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError) as exc:
        append_summary(f"### Agent evidence assessment\nUnable to retrieve PR evidence comments ({type(exc).__name__}); assessment unavailable (report-only).")
        return 0

    try:
        found = extract_evidence_comment(comments)
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        append_summary(f"### Agent evidence assessment\nThe marked evidence comment is malformed ({type(exc).__name__}); evidence is not review-ready.")
        return 0

    if found is None:
        append_summary(
            "### Agent evidence assessment\n"
            f"No evidence comment was found among the latest 100 PR comments. "
            f"Submit a comment containing `{MARKER}` followed by a fenced JSON evidence object. "
            "This is informational only."
        )
        return 0

    evidence_bytes, comment = found
    try:
        validate_target_binding(evidence_bytes, repo, number, head_sha)
    except (ValueError, TypeError, json.JSONDecodeError) as exc:
        append_summary(f"### Agent evidence assessment\\nEvidence is bound to the wrong PR or commit ({exc}); it is not review-ready.")
        return 0

    with tempfile.TemporaryDirectory(prefix="fsa-agent-evidence-") as temp_dir:
        evidence_file = Path(temp_dir) / "evidence.json"
        evidence_file.write_bytes(evidence_bytes)
        result = subprocess.run(
            [sys.executable, str(validator), str(evidence_file), "--policy", str(policy)],
            capture_output=True,
            text=True,
            check=False,
        )

    provenance = (
        f"Evidence comment author: `{comment['author']}`; "
        f"created: `{comment['created_at']}`; "
        f"comment ID: `{comment['comment_id']}`."
    )
    if result.returncode == 0:
        heading = "### Agent evidence assessment\n**Evidence readiness: passed** (report-only; not an approval)."
    else:
        heading = "### Agent evidence assessment\n**Evidence readiness: blocked / incomplete** (report-only; this does not change PR Gate status)."
    details = (result.stdout + result.stderr).strip()
    append_summary(heading + "\n\n" + provenance + ("\n\n```text\n" + details + "\n```" if details else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
