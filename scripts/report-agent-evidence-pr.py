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
from urllib.parse import urlparse

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


def verify_accountable_human(evidence: dict, pull_request: dict, policy: dict) -> None:
    """Bind the named accountable human to the PR author or an assigned human."""
    if not policy.get("accountable_human_must_be_author_or_assignee", True):
        return
    login = evidence.get("accountable_human")
    allowed = set()
    author = pull_request.get("user") or {}
    if author.get("type") == "User" and isinstance(author.get("login"), str):
        allowed.add(author["login"])
    for assignee in pull_request.get("assignees", []):
        if isinstance(assignee, dict) and assignee.get("type") == "User":
            if isinstance(assignee.get("login"), str):
                allowed.add(assignee["login"])
    if not isinstance(login, str) or login not in allowed:
        raise ValueError("accountable_human must be the PR author or an assigned human")


def parse_github_run_url(run_url: str, repo: str) -> int:
    """Accept only workflow-run URLs from this repository."""
    parsed = urlparse(run_url)
    if parsed.scheme != "https" or parsed.hostname != "github.com":
        raise ValueError("no verification adapter is registered for this CI provider")
    match = re.fullmatch(rf"/{re.escape(repo)}/actions/runs/(\d+)", parsed.path.rstrip("/"))
    if not match:
        raise ValueError("run URL must identify a GitHub Actions workflow run in this repository")
    return int(match.group(1))


def github_api_json(url: str, token: str) -> dict:
    request = Request(url, headers={
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "fork-sync-all-agent-evidence-report",
    })
    with urlopen(request, timeout=15) as response:
        return json.loads(response.read().decode("utf-8"))


def verify_run_references(evidence: dict, policy: dict, repo: str, head_sha: str,
                          token: str, api_url: str) -> list[str]:
    """Verify required GitHub Actions jobs against live run metadata."""
    errors = []
    validations = {
        item.get("check_id"): item
        for item in evidence.get("validations", [])
        if isinstance(item, dict) and isinstance(item.get("check_id"), str)
    }
    aliases = policy.get("github_job_name_aliases", {})
    cache = {}
    for check_id in policy.get("required_checks", []):
        item = validations.get(check_id)
        if not item:
            errors.append(f"required validation missing: {check_id}")
            continue
        run_url = item.get("run_url")
        if not isinstance(run_url, str) or not run_url:
            errors.append(f"required validation has no run URL: {check_id}")
            continue
        try:
            run_id = parse_github_run_url(run_url, repo)
            if run_id not in cache:
                run = github_api_json(f"{api_url}/repos/{repo}/actions/runs/{run_id}", token)
                jobs_response = github_api_json(
                    f"{api_url}/repos/{repo}/actions/runs/{run_id}/jobs?per_page=100", token
                )
                cache[run_id] = (run, jobs_response.get("jobs", []))
            run, jobs = cache[run_id]
        except (ValueError, TypeError, HTTPError, URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
            errors.append(f"unable to verify {check_id} run reference: {type(exc).__name__}: {exc}")
            continue

        if run.get("head_sha") != head_sha:
            errors.append(f"{check_id} workflow run does not target the current PR head SHA")
        if run.get("status") != "completed" or run.get("conclusion") != "success":
            errors.append(f"{check_id} workflow run is not completed successfully")
        expected_names = aliases.get(check_id, [])
        if not expected_names:
            errors.append(f"no trusted GitHub job-name mapping is configured for {check_id}")
            continue
        matching = [job for job in jobs if job.get("name") in expected_names]
        if not matching:
            errors.append(f"{check_id} run contains no allowlisted job: {', '.join(expected_names)}")
        elif not any(job.get("status") == "completed" and job.get("conclusion") == "success" for job in matching):
            errors.append(f"{check_id} allowlisted job did not complete successfully")
    return errors


def append_summary(message: str) -> None:
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as summary:
            summary.write(message.rstrip() + "\n")


def finish_report(status: str, summary: str, **fields: object) -> int:
    """Emit one stable JSON report for Actions summaries and the FSA API."""
    append_summary(summary)
    report = {
        "ok": status != "unavailable",
        "ready": status == "passed",
        "status": status,
        "report_only": True,
        "summary": summary,
    }
    report.update(fields)
    print(json.dumps(report, sort_keys=True))
    return 0


def main() -> int:
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    number = os.environ.get("PR_NUMBER", "")
    head_sha = os.environ.get("PR_HEAD_SHA", "")
    token = os.environ.get("GITHUB_TOKEN", "")
    api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    repo_root = Path(__file__).resolve().parents[1]
    validator = repo_root / "scripts/validate-agent-evidence.py"
    policy = repo_root / "config/agent-accountability-policy.yml"

    if not validator.is_file() or not policy.is_file():
        return finish_report(
            "unavailable",
            "The trusted base branch does not yet contain the evidence evaluator; report-only assessment is unavailable.",
        )
    if not (repo and number.isdigit() and head_sha and token):
        return finish_report(
            "unavailable",
            "Required PR metadata or read-only token is unavailable; no evidence conclusion was made.",
        )

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
        return finish_report(
            "unavailable",
            f"GitHub API returned HTTP {exc.code}; assessment unavailable (report-only).",
        )
    except (URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError) as exc:
        return finish_report(
            "unavailable",
            f"Unable to retrieve PR evidence comments ({type(exc).__name__}); assessment unavailable (report-only).",
        )

    try:
        found = extract_evidence_comment(comments)
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        return finish_report(
            "invalid",
            f"The marked evidence comment is malformed ({type(exc).__name__}); evidence is not review-ready.",
        )

    if found is None:
        return finish_report(
            "missing",
            f"No evidence comment was found among the latest 100 PR comments. "
            f"Submit a comment containing {MARKER} followed by a fenced JSON evidence object. "
            "This is informational only.",
        )

    evidence_bytes, comment = found
    try:
        validate_target_binding(evidence_bytes, repo, number, head_sha)
        evidence_object = json.loads(evidence_bytes.decode("utf-8"))
        import yaml
        policy_object = yaml.safe_load(policy.read_text(encoding="utf-8")) or {}
        pull_request = github_api_json(f"{api_url}/repos/{repo}/pulls/{number}", token)
        if (pull_request.get("head") or {}).get("sha") != head_sha:
            raise ValueError("live PR head SHA changed during evidence assessment")
        verify_accountable_human(evidence_object, pull_request, policy_object)
        verification_errors = verify_run_references(
            evidence_object, policy_object, repo, head_sha, token, api_url
        )
    except Exception as exc:
        return finish_report(
            "blocked",
            f"Evidence could not be verified ({type(exc).__name__}: {exc}); it is not review-ready.",
        )

    if verification_errors:
        return finish_report(
            "unverifiable",
            "Evidence readiness: blocked / unverifiable (report-only).",
            errors=verification_errors,
            comment=comment,
        )

    try:
        with tempfile.TemporaryDirectory(prefix="fsa-agent-evidence-") as temp_dir:
            evidence_file = Path(temp_dir) / "evidence.json"
            evidence_file.write_bytes(evidence_bytes)
            result = subprocess.run(
                [sys.executable, str(validator), str(evidence_file), "--policy", str(policy)],
                capture_output=True,
                text=True,
                check=False,
                cwd=repo_root,
            )
    except OSError as exc:
        return finish_report(
            "unavailable",
            f"Unable to execute the trusted evidence validator ({type(exc).__name__}).",
            comment=comment,
        )

    details = (result.stdout + result.stderr).strip()
    provenance = (
        f"Evidence comment author: {comment['author']}; "
        f"created: {comment['created_at']}; comment ID: {comment['comment_id']}."
    )
    if result.returncode == 0:
        summary = (
            "Evidence readiness: passed (report-only; not an approval). "
            + provenance
        )
        return finish_report("passed", summary, comment=comment, details=details)
    summary = (
        "Evidence readiness: blocked / incomplete (report-only; this does not change PR Gate status). "
        + provenance
    )
    return finish_report("blocked", summary, comment=comment, details=details)


if __name__ == "__main__":
    raise SystemExit(main())
