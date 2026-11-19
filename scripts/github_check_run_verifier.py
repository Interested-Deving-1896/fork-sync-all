"""Fail-closed correlation verifier for GitHub Check Runs and Actions attempts.

The verifier proves the supplied check-run IDs belong to the exact requested
Actions run attempt and head SHA before annotation retrieval. It is read-only.
"""
from __future__ import annotations

import argparse
from dataclasses import asdict
from datetime import datetime, timezone
from enum import Enum
import json
import os
from pathlib import Path
import time
from typing import Any
from urllib.parse import urlparse

from diagnostic_evidence import (EvidenceCorrelationError, EvidenceRecord,
    Provenance, RetrievalStatus, redact_text)
from github_diagnostic_adapter import GitHubCheckRunsAdapter


class GitHubCheckRunVerifier:
    """Verify check-run identity through authoritative run-attempt job metadata."""

    def __init__(self, adapter: GitHubCheckRunsAdapter):
        self._adapter = adapter

    @staticmethod
    def _check_run_id_from_job(job: dict[str, Any], repository: str) -> int | None:
        url = job.get("check_run_url")
        if not isinstance(url, str):
            return None
        parsed = urlparse(url)
        expected_path = f"/repos/{repository}/check-runs/"
        if parsed.scheme != "https" or parsed.hostname != "api.github.com":
            return None
        if parsed.username or parsed.password or parsed.port not in (None, 443):
            return None
        if not parsed.path.startswith(expected_path):
            return None
        suffix = parsed.path[len(expected_path):]
        return int(suffix) if suffix.isdigit() else None

    def verify(self, provenance: Provenance, check_run_ids: list[int]) -> dict[int, int]:
        """Return {check_run_id: job_id}; raise on any missing/mismatched link.

        No caller-supplied ID is accepted merely because its annotation endpoint
        responds. The exact attempt metadata and all job pages must be retrieved.
        """
        if not check_run_ids or any(type(value) is not int or value <= 0 for value in check_run_ids):
            raise EvidenceCorrelationError("positive check-run IDs are required")
        if len(set(check_run_ids)) != len(check_run_ids):
            raise EvidenceCorrelationError("check-run IDs must be unique")

        deadline = time.monotonic() + self._adapter._deadline_seconds
        base = f"https://api.github.com/repos/{provenance.repository}"
        attempt_url = (
            f"{base}/actions/runs/{provenance.run_id}/attempts/{provenance.attempt}"
        )
        run, _ = self._adapter._get_json(attempt_url, deadline)
        if not isinstance(run, dict):
            raise EvidenceCorrelationError("attempt metadata is not an object")
        if run.get("id") != provenance.run_id:
            raise EvidenceCorrelationError("attempt metadata run ID mismatch")
        if run.get("run_attempt") != provenance.attempt:
            raise EvidenceCorrelationError("attempt metadata attempt mismatch")
        observed_sha = run.get("head_sha")
        if not isinstance(observed_sha, str) or observed_sha.lower() != provenance.head_sha.lower():
            raise EvidenceCorrelationError("attempt metadata head SHA mismatch")

        jobs_url = (
            f"{base}/actions/runs/{provenance.run_id}/attempts/{provenance.attempt}/jobs?per_page=100"
        )
        jobs, pages, complete = self._adapter._paginate(jobs_url, deadline)
        if not complete or pages < 1:
            raise EvidenceCorrelationError("job pagination incomplete; cannot prove check-run linkage")

        matches: dict[int, int] = {}
        for job in jobs:
            if job.get("run_id") != provenance.run_id:
                continue
            if job.get("run_attempt") != provenance.attempt:
                continue
            job_sha = job.get("head_sha")
            if not isinstance(job_sha, str) or job_sha.lower() != provenance.head_sha.lower():
                continue
            check_run_id = self._check_run_id_from_job(job, provenance.repository)
            if check_run_id in check_run_ids:
                job_id = job.get("id")
                if type(job_id) is not int or job_id <= 0:
                    raise EvidenceCorrelationError("matched job has no valid job ID")
                if check_run_id in matches:
                    raise EvidenceCorrelationError("duplicate job-to-check-run association")
                matches[check_run_id] = job_id

        missing = sorted(set(check_run_ids) - set(matches))
        if missing:
            raise EvidenceCorrelationError(
                "check-run IDs are not linked to the requested run attempt and head SHA: "
                + ", ".join(str(value) for value in missing)
            )
        return matches



def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--attempt", required=True, type=int)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--jobs-json", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    token = os.environ.get("GH_TOKEN", "")
    output = Path(args.output)
    jobs_path = Path(args.jobs_json)
    retrieved_at = datetime.now(timezone.utc).isoformat()
    provenance = Provenance(args.repository, args.run_id, args.attempt, args.head_sha)
    try:
        jobs_payload = json.loads(jobs_path.read_text(encoding="utf-8"))
        jobs = jobs_payload.get("jobs") if isinstance(jobs_payload, dict) else None
        if not isinstance(jobs, list) or any(not isinstance(job, dict) for job in jobs):
            raise EvidenceCorrelationError("verified jobs payload is malformed")
        candidates = sorted({
            check_id for job in jobs
            if (check_id := GitHubCheckRunVerifier._check_run_id_from_job(job, args.repository)) is not None
        })
        if len(candidates) > 100:
            raise EvidenceCorrelationError("check-run candidate limit exceeded")
        if not candidates:
            record = EvidenceRecord(
                "1.0", "github.check-runs.annotations", provenance,
                RetrievalStatus.UNAVAILABLE, retrieved_at,
                errors=("no check-run associations were present in verified attempt jobs",),
                redaction_applied=True,
            )
        else:
            adapter = GitHubCheckRunsAdapter(token)
            verifier = GitHubCheckRunVerifier(adapter)
            verifier.verify(provenance, candidates)
            record = adapter.fetch_annotations(provenance, candidates)
    except Exception as exc:
        record = EvidenceRecord(
            "1.0", "github.check-runs.annotations", provenance,
            RetrievalStatus.FAILED, retrieved_at,
            errors=(redact_text(f"{type(exc).__name__}: {exc}"),),
            redaction_applied=True,
        )
    payload = asdict(record)
    payload["status"] = record.status.value
    output.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(json.dumps({
        "status": record.status.value, "check_run_count": len(candidates) if "candidates" in locals() else 0,
        "annotation_count": len(record.records), "pages_read": record.pages_read,
    }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
