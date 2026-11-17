#!/usr/bin/env python3
"""Report-only PR evidence assessment using trusted base-branch code.

This helper never changes PR state and never turns an evidence result into
approval, merge authority, or a required-check decision.
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def decode_contents_response(payload: str) -> bytes:
    """Decode a GitHub Contents API response without trusting its contents."""
    response = json.loads(payload)
    encoded = response.get("content")
    if not isinstance(encoded, str):
        raise ValueError("GitHub Contents response has no base64 content")
    compact = "".join(encoded.split())
    decoded = base64.b64decode(compact, validate=True)
    if len(decoded) > 262144:
        raise ValueError("evidence artifact exceeds the 256 KiB limit")
    return decoded


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

    evidence_path = f".fsa/evidence/pr-{number}.json"
    url = f"{api_url}/repos/{repo}/contents/{evidence_path}?ref={head_sha}"
    request = Request(url, headers={
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "fork-sync-all-agent-evidence-report",
    })

    try:
        with urlopen(request, timeout=15) as response:
            payload = response.read().decode("utf-8")
    except HTTPError as exc:
        if exc.code == 404:
            append_summary(
                "### Agent evidence assessment\n"
                f"No evidence artifact was supplied at `{evidence_path}`. "
                "This is informational only; the PR Gate remains governed by its existing checks."
            )
            return 0
        append_summary(f"### Agent evidence assessment\nGitHub API returned HTTP {exc.code}; assessment unavailable (report-only).")
        return 0
    except (URLError, TimeoutError, OSError) as exc:
        append_summary(f"### Agent evidence assessment\nUnable to retrieve evidence ({type(exc).__name__}); assessment unavailable (report-only).")
        return 0

    try:
        evidence_bytes = decode_contents_response(payload)
        evidence_bytes.decode("utf-8")
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        append_summary(f"### Agent evidence assessment\nEvidence artifact could not be decoded ({type(exc).__name__}); it is not review-ready.")
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

    if result.returncode == 0:
        heading = "### Agent evidence assessment\n**Evidence readiness: passed** (report-only; not an approval)."
    else:
        heading = "### Agent evidence assessment\n**Evidence readiness: blocked / incomplete** (report-only; this does not change PR Gate status)."
    details = (result.stdout + result.stderr).strip()
    append_summary(heading + ("\n\n```text\n" + details + "\n```" if details else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
