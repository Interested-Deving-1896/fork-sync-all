"""Bounded, read-only GitHub Check Runs adapter for diagnostic evidence.

This adapter intentionally retrieves Check Runs and their annotations only.
Callers must supply check-run IDs already correlated to a verified Actions run
attempt and head SHA. It never guesses an attempt from the latest run.
"""
from __future__ import annotations

from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
import json
import time
from typing import Any, Callable, Mapping
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener

from diagnostic_evidence import (
    EvidenceCorrelationError,
    EvidenceError,
    EvidenceRecord,
    Provenance,
    RetrievalStatus,
    normalize_annotation,
    redact_text,
)

API_ORIGIN = ("https", "api.github.com", 443)
MAX_PAGES = 20
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
DEFAULT_TIMEOUT = 10.0
DEFAULT_RETRIES = 2
RETRYABLE = {429, 500, 502, 503, 504}


class AdapterError(RuntimeError):
    """A bounded GitHub API retrieval failed."""


class _SameOriginRedirects(HTTPRedirectHandler):
    """Allow API pagination redirects only when they remain on api.github.com."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        target = urlparse(urljoin(req.full_url, newurl))
        origin = (target.scheme, target.hostname, target.port or 443)
        if origin != API_ORIGIN:
            raise AdapterError("refusing cross-origin redirect for authenticated API request")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _urllib_request(url: str, headers: Mapping[str, str], timeout: float,
                    max_bytes: int) -> tuple[int, Mapping[str, str], bytes]:
    opener = build_opener(_SameOriginRedirects())
    request = Request(url, headers=dict(headers), method="GET")
    try:
        with opener.open(request, timeout=timeout) as response:
            body = response.read(max_bytes + 1)
            if len(body) > max_bytes:
                raise AdapterError("GitHub API response exceeded byte limit")
            return response.status, dict(response.headers.items()), body
    except HTTPError as exc:
        body = exc.read(max_bytes + 1)
        if len(body) > max_bytes:
            raise AdapterError("GitHub API error response exceeded byte limit") from exc
        return exc.code, dict(exc.headers.items()), body
    except (URLError, TimeoutError, OSError) as exc:
        raise AdapterError(f"GitHub API transport failed: {type(exc).__name__}") from exc


class GitHubCheckRunsAdapter:
    """Fetch bounded Check Run annotation pages using an injectable transport."""

    def __init__(self, token: str, *, request: Callable = _urllib_request,
                 timeout: float = DEFAULT_TIMEOUT, retries: int = DEFAULT_RETRIES,
                 max_pages: int = MAX_PAGES, max_response_bytes: int = MAX_RESPONSE_BYTES,
                 deadline_seconds: float = 45.0, sleep: Callable = time.sleep):
        if not token:
            raise ValueError("a GitHub token is required")
        if timeout <= 0 or retries < 0 or max_pages < 1 or max_response_bytes < 1 or deadline_seconds <= 0:
            raise ValueError("adapter limits must be positive (retries may be zero)")
        self._headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "fork-sync-all-diagnostic-evidence",
        }
        self._request = request
        self._timeout = timeout
        self._retries = retries
        self._max_pages = max_pages
        self._max_bytes = max_response_bytes
        self._deadline_seconds = deadline_seconds
        self._sleep = sleep

    def _get_json(self, url: str, deadline: float) -> tuple[Any, Mapping[str, str]]:
        parsed = urlparse(url)
        if (parsed.scheme, parsed.hostname, parsed.port or 443) != API_ORIGIN:
            raise AdapterError("only HTTPS api.github.com endpoints are allowed")
        attempt = 0
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AdapterError("overall retrieval deadline exceeded")
            try:
                status, headers, body = self._request(
                    url, self._headers, min(self._timeout, remaining), self._max_bytes
                )
            except AdapterError:
                if attempt >= self._retries:
                    raise
                attempt += 1
                self._sleep(min(0.25 * (2 ** (attempt - 1)), max(0, deadline - time.monotonic())))
                continue
            if status in RETRYABLE and attempt < self._retries:
                retry_after = headers.get("Retry-After", "")
                try:
                    delay = min(float(retry_after), 5.0) if retry_after else 0.25 * (2 ** attempt)
                except ValueError:
                    delay = 0.25 * (2 ** attempt)
                attempt += 1
                if time.monotonic() + delay >= deadline:
                    raise AdapterError("retry would exceed overall retrieval deadline")
                self._sleep(delay)
                continue
            if status < 200 or status >= 300:
                raise AdapterError(f"GitHub API returned HTTP {status}")
            try:
                return json.loads(body.decode("utf-8")), headers
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise AdapterError("GitHub API returned invalid JSON") from exc

    @staticmethod
    def _next_link(link_header: str) -> str | None:
        for part in link_header.split(","):
            section = part.strip()
            if 'rel="next"' not in section:
                continue
            left, _, right = section.partition(";")
            if not left.startswith("<") or not left.endswith(">"):
                raise AdapterError("malformed GitHub pagination Link header")
            return left[1:-1]
        return None

    def _paginate(self, url: str, deadline: float) -> tuple[list[dict[str, Any]], int, bool]:
        rows: list[dict[str, Any]] = []
        pages = 0
        next_url: str | None = url
        while next_url:
            if pages >= self._max_pages:
                return rows, pages, False
            payload, headers = self._get_json(next_url, deadline)
            if not isinstance(payload, list):
                raise AdapterError("expected a JSON array from annotations endpoint")
            if any(not isinstance(row, dict) for row in payload):
                raise AdapterError("annotation response contains a non-object record")
            rows.extend(payload)
            pages += 1
            next_url = self._next_link(headers.get("Link", ""))
        return rows, pages, True

    def fetch_annotations(self, provenance: Provenance, check_run_ids: list[int]) -> EvidenceRecord:
        """Fetch annotations for caller-verified check runs, never infer run linkage.

        The caller must first correlate each check_run_id to provenance.run_id,
        provenance.attempt and provenance.head_sha using verified Actions metadata.
        """
        retrieved_at = datetime.now(timezone.utc).isoformat()
        if not check_run_ids or any(not isinstance(x, int) or x <= 0 for x in check_run_ids):
            raise EvidenceError("one or more verified positive check_run_ids are required")
        if len(set(check_run_ids)) != len(check_run_ids):
            raise EvidenceError("check_run_ids must be unique")
        if provenance.check_run_id is not None and check_run_ids != [provenance.check_run_id]:
            raise EvidenceCorrelationError("requested check-run IDs differ from provenance")
        deadline = time.monotonic() + self._deadline_seconds
        normalized: list[dict[str, Any]] = []
        errors: list[str] = []
        total_pages = 0
        for check_run_id in check_run_ids:
            base = f"https://api.github.com/repos/{provenance.repository}/check-runs/{check_run_id}/annotations?per_page=100"
            try:
                raw, pages, expected_pages = self._paginate(base, deadline)
                total_pages += pages
                for annotation in raw:
                    normalized.append(normalize_annotation(
                        {**annotation, "check_run_id": check_run_id,
                         "head_sha": provenance.head_sha},
                        check_run_id=check_run_id, head_sha=provenance.head_sha
                    ))
                if not expected_pages:
                    errors.append(
                        f"check run {check_run_id}: pagination page limit reached before completion"
                    )
                    break
            except (AdapterError, EvidenceError) as exc:
                errors.append(redact_text(f"check run {check_run_id}: {exc}"))
                break
        status = RetrievalStatus.SUCCESS if not errors else (
            RetrievalStatus.PARTIAL if normalized or total_pages else RetrievalStatus.FAILED
        )
        return EvidenceRecord(
            schema_version="1.0",
            source="github.check-runs.annotations",
            provenance=provenance,
            status=status,
            retrieved_at=retrieved_at,
            records=tuple(normalized),
            errors=tuple(errors),
            pages_read=total_pages,
            pages_expected=total_pages if status == RetrievalStatus.SUCCESS else None,
            redaction_applied=True,
        )
