#!/usr/bin/env python3
"""Cancel non-manual workflow runs that captured secrets before a rotation."""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime


API = os.environ.get("GH_API", "https://api.github.com")


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def should_cancel(
    run: dict,
    *,
    current_run_id: int,
    rotation_started: datetime,
) -> tuple[bool, str]:
    """Return whether a run predates the rotation and is safe to cancel."""
    if int(run["id"]) == current_run_id:
        return False, "rotation-run"
    if run.get("event") == "workflow_dispatch":
        return False, "manual-dispatch"
    if parse_time(run["created_at"]) >= rotation_started:
        return False, "post-rotation"
    return True, "pre-rotation"


class GitHub:
    def __init__(self, token: str, repo: str) -> None:
        self.repo = repo
        self.headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        }

    def request(self, path: str, *, method: str = "GET") -> tuple[int, dict]:
        data = b"{}" if method != "GET" else None
        request = urllib.request.Request(
            f"{API}/repos/{self.repo}{path}",
            data=data,
            headers={**self.headers, "Content-Type": "application/json"},
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                return response.status, json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            return error.code, {}

    def runs(self, status: str) -> list[dict]:
        result: list[dict] = []
        page = 1
        while True:
            code, body = self.request(
                f"/actions/runs?status={status}&per_page=100&page={page}"
            )
            if code != 200:
                raise RuntimeError(f"HTTP {code} listing {status} runs")
            batch = body.get("workflow_runs", [])
            result.extend(batch)
            if len(batch) < 100:
                return result
            page += 1


def main() -> int:
    token = os.environ.get("GH_TOKEN", "")
    repo = os.environ.get("REPO", "")
    current_run_id = int(os.environ.get("ROTATION_RUN_ID", "0"))
    if not token or not repo or not current_run_id:
        print("GH_TOKEN, REPO, and ROTATION_RUN_ID are required", file=sys.stderr)
        return 2

    github = GitHub(token, repo)
    code, rotation = github.request(f"/actions/runs/{current_run_id}")
    if code != 200 or not rotation.get("created_at"):
        print(
            f"Could not resolve rotation run {current_run_id} (HTTP {code})",
            file=sys.stderr,
        )
        return 1

    rotation_started = parse_time(rotation["created_at"])
    candidates = github.runs("queued") + github.runs("in_progress")
    cancelled: list[int] = []
    skipped: list[tuple[int, str]] = []
    failed: list[tuple[int, int]] = []

    for run in {int(item["id"]): item for item in candidates}.values():
        cancel, reason = should_cancel(
            run,
            current_run_id=current_run_id,
            rotation_started=rotation_started,
        )
        run_id = int(run["id"])
        if not cancel:
            skipped.append((run_id, reason))
            continue

        status, _ = github.request(f"/actions/runs/{run_id}/cancel", method="POST")
        if status in (202, 204):
            cancelled.append(run_id)
            print(f"Cancelled {run.get('name', 'unknown')} (run {run_id})")
        else:
            failed.append((run_id, status))
            print(f"WARNING: HTTP {status} cancelling run {run_id}", file=sys.stderr)

    print(
        f"Summary: {len(cancelled)} cancelled, {len(skipped)} skipped, "
        f"{len(failed)} failed"
    )
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as output:
            output.write("## Post-Rotation Cleanup\n\n")
            output.write(f"- **Rotation cutoff**: {rotation_started.isoformat()}\n")
            output.write(f"- **Cancelled**: {len(cancelled)}\n")
            output.write(f"- **Skipped**: {len(skipped)}\n")
            output.write(f"- **Cancellation failures**: {len(failed)}\n")

    # A failed cancellation is reported but does not misreport the completed
    # secret rotation itself as failed; queue-manager can retry stale records.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
