"""Bounded, fail-closed GitHub Actions attempt and log retrieval.

The API request is authenticated only against api.github.com. A 302 log URL is
validated as HTTPS and fetched in a separate unauthenticated request, so the
GitHub bearer token is never forwarded to external object storage. ZIP content
is bounded and inspected in memory; this module never extracts files.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import argparse
import io
import json
import os
import time
from pathlib import Path
from typing import Callable, Mapping
from urllib.parse import urljoin, urlparse
from urllib.request import Request, build_opener, HTTPRedirectHandler
from urllib.error import HTTPError, URLError
from zipfile import BadZipFile, ZipFile

API_ORIGIN = ("https", "api.github.com", 443)
DEFAULT_MAX_BYTES = 50 * 1024 * 1024
DEFAULT_MAX_PAGES = 20


class RetrievalError(RuntimeError):
    """Retrieval failed or violated a safety bound."""


@dataclass(frozen=True)
class AttemptEvidence:
    repository: str
    run_id: int
    attempt: int
    head_sha: str
    run: Mapping
    jobs: tuple[Mapping, ...]
    log_files: Mapping[str, str]
    logs_status: str
    retrieved_at: str


def _no_redirect_request(url: str, headers: Mapping[str, str],
                         timeout: float, max_bytes: int):
    class NoRedirect(HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    opener = build_opener(NoRedirect())
    req = Request(url, headers=dict(headers), method="GET")
    try:
        with opener.open(req, timeout=timeout) as response:
            body = response.read(max_bytes + 1)
            return response.status, dict(response.headers.items()), body
    except HTTPError as exc:
        body = exc.read(max_bytes + 1)
        return exc.code, dict(exc.headers.items()), body
    except (URLError, TimeoutError, OSError) as exc:
        raise RetrievalError(f"HTTP transport failed: {type(exc).__name__}") from exc


class GitHubActionsLogAdapter:
    def __init__(self, token: str, *, request: Callable = _no_redirect_request,
                 timeout: float = 10.0, max_bytes: int = DEFAULT_MAX_BYTES,
                 max_pages: int = DEFAULT_MAX_PAGES, deadline_seconds: float = 60.0):
        if not token or timeout <= 0 or max_bytes <= 0 or max_pages <= 0 or deadline_seconds <= 0:
            raise ValueError("token and positive retrieval limits are required")
        self._token = token
        self._request = request
        self._timeout = timeout
        self._max_bytes = max_bytes
        self._max_pages = max_pages
        self._deadline_seconds = deadline_seconds

    def _get_api(self, url: str, deadline: float):
        parsed = urlparse(url)
        if (parsed.scheme, parsed.hostname, parsed.port or 443) != API_ORIGIN:
            raise RetrievalError("authenticated requests are restricted to HTTPS api.github.com")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RetrievalError("overall retrieval deadline exceeded")
        status, headers, body = self._request(
            url,
            {"Accept": "application/vnd.github+json",
             "Authorization": f"Bearer {self._token}",
             "X-GitHub-Api-Version": "2022-11-28",
             "User-Agent": "fork-sync-all-diagnostic-evidence"},
            min(self._timeout, remaining), self._max_bytes)
        if len(body) > self._max_bytes:
            raise RetrievalError("API response exceeded byte limit")
        return status, headers, body

    @staticmethod
    def _next_url(headers: Mapping[str, str]) -> str | None:
        link = headers.get("Link", "")
        for item in link.split(","):
            part = item.strip()
            if 'rel="next"' in part:
                left = part.split(";", 1)[0].strip()
                if not (left.startswith("<") and left.endswith(">")):
                    raise RetrievalError("malformed pagination Link header")
                return left[1:-1]
        return None

    def _json(self, url: str, deadline: float):
        status, headers, body = self._get_api(url, deadline)
        if status != 200:
            raise RetrievalError(f"GitHub API returned HTTP {status}")
        try:
            return json.loads(body.decode("utf-8")), headers
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise RetrievalError("GitHub API returned invalid JSON") from exc

    def _jobs(self, repository: str, run_id: int, attempt: int, deadline: float):
        url = (f"https://api.github.com/repos/{repository}/actions/runs/"
               f"{run_id}/attempts/{attempt}/jobs?per_page=100")
        rows, pages = [], 0
        while url:
            if pages >= self._max_pages:
                raise RetrievalError("jobs pagination page limit reached")
            payload, headers = self._json(url, deadline)
            if not isinstance(payload, dict) or not isinstance(payload.get("jobs"), list):
                raise RetrievalError("jobs endpoint returned malformed payload")
            rows.extend(payload["jobs"])
            pages += 1
            url = self._next_url(headers)
        return rows

    def _logs(self, repository: str, run_id: int, attempt: int, deadline: float):
        url = (f"https://api.github.com/repos/{repository}/actions/runs/"
               f"{run_id}/attempts/{attempt}/logs")
        status, headers, body = self._get_api(url, deadline)
        if status not in (301, 302, 303, 307, 308):
            if status == 410:
                return {}, "expired"
            if status in (204, 404):
                return {}, "unavailable"
            raise RetrievalError(f"logs endpoint returned HTTP {status}, not a redirect")
        location = headers.get("Location") or headers.get("location")
        if not location:
            raise RetrievalError("logs redirect omitted Location")
        target = urlparse(urljoin(url, location))
        if (target.scheme != "https" or not target.hostname or target.username
                or target.password or target.port not in (None, 443)
                or target.hostname.lower() == "api.github.com"):
            raise RetrievalError("unsafe external log-storage URL")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RetrievalError("overall retrieval deadline exceeded before log download")
        # Crucial: no Authorization or other GitHub credentials on this request.
        status, response_headers, archive = self._request(
            target.geturl(), {"Accept": "application/zip"},
            min(self._timeout, remaining), self._max_bytes)
        if status != 200:
            raise RetrievalError(f"external log storage returned HTTP {status}")
        if len(archive) > self._max_bytes:
            raise RetrievalError("log archive exceeded byte limit")
        try:
            with ZipFile(io.BytesIO(archive)) as zf:
                files = {}
                total = 0
                for info in zf.infolist():
                    if info.is_dir():
                        continue
                    if info.file_size < 0 or info.file_size > self._max_bytes:
                        raise RetrievalError("individual log entry exceeded byte limit")
                    total += info.file_size
                    if total > self._max_bytes:
                        raise RetrievalError("expanded log archive exceeded byte limit")
                    if (info.filename.startswith("/") or "\\" in info.filename
                            or ":" in info.filename
                            or ".." in info.filename.split("/")):
                        raise RetrievalError("unsafe path in log archive")
                    mode = (info.external_attr >> 16) & 0o170000
                    if mode not in (0, 0o100000):
                        raise RetrievalError("non-regular file in log archive")
                    raw = zf.read(info)
                    files[info.filename] = raw.decode("utf-8", errors="replace")
                return files, "success"
        except BadZipFile as exc:
            raise RetrievalError("GitHub returned an invalid log ZIP") from exc

    def retrieve(self, repository: str, run_id: int, attempt: int,
                 expected_head_sha: str) -> AttemptEvidence:
        if (not repository or repository.count("/") != 1 or run_id <= 0
                or attempt <= 0 or len(expected_head_sha) not in (40, 64)
                or any(c not in "0123456789abcdefABCDEF" for c in expected_head_sha)):
            raise ValueError("repository, positive run/attempt, and full SHA are required")
        deadline = time.monotonic() + self._deadline_seconds
        run_url = (f"https://api.github.com/repos/{repository}/actions/runs/"
                   f"{run_id}/attempts/{attempt}")
        run, _ = self._json(run_url, deadline)
        if (run.get("id") != run_id or run.get("run_attempt") != attempt
                or str(run.get("head_sha", "")).lower() != expected_head_sha.lower()):
            raise RetrievalError("workflow run metadata does not match requested run/attempt/SHA")
        jobs = self._jobs(repository, run_id, attempt, deadline)
        for job in jobs:
            if (job.get("run_id") != run_id or job.get("run_attempt") != attempt
                    or str(job.get("head_sha", "")).lower() != expected_head_sha.lower()):
                raise RetrievalError("job metadata does not match requested run/attempt/SHA")
        try:
            files, logs_status = self._logs(repository, run_id, attempt, deadline)
        except RetrievalError:
            # Run/job evidence remains usable; log retrieval is explicitly marked
            # failed and never silently represented as a successful empty archive.
            files, logs_status = {}, "failed"
        return AttemptEvidence(repository, run_id, attempt, expected_head_sha.lower(),
                               run, tuple(jobs), files, logs_status,
                               datetime.now(timezone.utc).isoformat())


def _write_private(path: Path, content: str) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(content)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--attempt", required=True, type=int)
    parser.add_argument("--expected-head-sha", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    token = os.environ.get("GH_TOKEN", "")
    output = Path(args.output_dir)
    if not output.is_dir():
        parser.error("--output-dir must be an existing private directory")
    evidence = GitHubActionsLogAdapter(token).retrieve(
        args.repository, args.run_id, args.attempt, args.expected_head_sha)
    _write_private(output / "run.json", json.dumps(evidence.run))
    _write_private(output / "jobs.json", json.dumps({"jobs": evidence.jobs}))
    _write_private(output / "logs-status.txt", evidence.logs_status + "\n")
    for name, content in evidence.log_files.items():
        target = (output / "logs" / name).resolve()
        root = (output / "logs").resolve()
        if target != root and root not in target.parents:
            raise RetrievalError("log path escaped private output directory")
        _write_private(target, content)
    print(json.dumps({
        "repository": evidence.repository, "run_id": evidence.run_id,
        "attempt": evidence.attempt, "head_sha": evidence.head_sha,
        "logs_status": evidence.logs_status,
        "job_count": len(evidence.jobs),
    }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
