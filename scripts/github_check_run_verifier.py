"""Fail-closed correlation verifier for GitHub Check Runs and Actions attempts.

The verifier proves the supplied check-run IDs belong to the exact requested
Actions run attempt and head SHA before annotation retrieval. It is read-only.
"""
from __future__ import annotations

import time
from typing import Any

from diagnostic_evidence import EvidenceCorrelationError, Provenance
from github_diagnostic_adapter import GitHubCheckRunsAdapter


class GitHubCheckRunVerifier:
    """Verify check-run identity through authoritative run-attempt job metadata."""

    def __init__(self, adapter: GitHubCheckRunsAdapter):
        self._adapter = adapter

    @staticmethod
    def _check_run_id_from_job(job: dict[str, Any]) -> int | None:
        url = job.get("check_run_url")
        if not isinstance(url, str):
            return None
        marker = "/check-runs/"
        if marker not in url:
            return None
        suffix = url.split(marker, 1)[1].split("?", 1)[0].rstrip("/")
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
            check_run_id = self._check_run_id_from_job(job)
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
