#!/usr/bin/env python3
"""Bounded, cache-aware GitHub Actions job-log retrieval.

The engine is read-only. It never reruns workflows, edits source, or dispatches jobs.
Credentials are read from the environment and are never written to cache/state.
"""
from __future__ import annotations

import argparse
from datetime import timezone
from email.utils import parsedate_to_datetime
import hashlib
import json
import os
import re
from pathlib import Path
import sys
import tempfile
import time
from dataclasses import dataclass
from typing import Callable, Mapping
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener


API_ROOT = "https://api.github.com"
DEFAULT_MAX_ATTEMPTS = 3
DEFAULT_DEADLINE_SECONDS = 90
DEFAULT_MAX_BYTES = 8 * 1024 * 1024
DEFAULT_CACHE_TTL_SECONDS = 6 * 60 * 60


class LogFetchError(RuntimeError):
    """A bounded log-fetch cycle could not return usable log content."""


@dataclass(frozen=True)
class HttpResponse:
    status: int
    headers: Mapping[str, str]
    body: bytes


class NoRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class UrllibTransport:
    """HTTP GET transport that does not forward credentials across redirects."""

    def __init__(self) -> None:
        self._opener = build_opener(NoRedirectHandler())

    def get(self, url: str, headers: Mapping[str, str], timeout: float,
            max_bytes: int) -> HttpResponse:
        request = Request(url, headers=dict(headers), method="GET")
        try:
            with self._opener.open(request, timeout=timeout) as response:
                body = response.read(max_bytes + 1)
                return HttpResponse(response.status, dict(response.headers), body)
        except HTTPError as exc:
            body = exc.read(max_bytes + 1)
            return HttpResponse(exc.code, dict(exc.headers or {}), body)


def _header(headers: Mapping[str, str], name: str) -> str | None:
    wanted = name.lower()
    for key, value in headers.items():
        if key.lower() == wanted:
            return str(value)
    return None


def _safe_redirect(url: str) -> bool:
    parsed = urlparse(url)
    return parsed.scheme == "https" and bool(parsed.hostname) and not parsed.username and not parsed.password


class GitHubJobLogFetcher:
    def __init__(self, token: str, *, transport=None, max_attempts: int = DEFAULT_MAX_ATTEMPTS,
                 deadline_seconds: int = DEFAULT_DEADLINE_SECONDS,
                 max_bytes: int = DEFAULT_MAX_BYTES, initial_backoff: float = 2,
                 max_backoff: float = 20, request_timeout: float = 20,
                 sleeper: Callable[[float], None] = time.sleep,
                 clock: Callable[[], float] = time.monotonic,
                 wall_clock: Callable[[], float] = time.time):
        if not token:
            raise LogFetchError("A runtime GitHub token is required")
        if not 1 <= max_attempts <= 5:
            raise LogFetchError("max_attempts must be between 1 and 5")
        if not 1 <= deadline_seconds <= 300:
            raise LogFetchError("deadline_seconds must be between 1 and 300")
        if not 1024 <= max_bytes <= 64 * 1024 * 1024:
            raise LogFetchError("max_bytes must be between 1024 and 67108864")
        self._token = token
        self._transport = transport or UrllibTransport()
        self._max_attempts = max_attempts
        self._deadline_seconds = deadline_seconds
        self._max_bytes = max_bytes
        self._initial_backoff = max(0.1, initial_backoff)
        self._max_backoff = max(self._initial_backoff, max_backoff)
        self._request_timeout = request_timeout
        self._sleep = sleeper
        self._clock = clock
        self._wall_clock = wall_clock

    def _get_with_redirects(self, url: str, *, authenticated: bool,
                            deadline: float) -> HttpResponse:
        headers = {"Accept": "application/vnd.github+json"}
        if authenticated:
            headers["Authorization"] = f"Bearer {self._token}"
            headers["X-GitHub-Api-Version"] = "2022-11-28"
        for _ in range(4):
            remaining = deadline - self._clock()
            if remaining <= 0:
                raise TimeoutError("log fetch deadline reached")
            response = self._transport.get(
                url, headers, min(self._request_timeout, remaining), self._max_bytes
            )
            if response.status not in (301, 302, 303, 307, 308):
                return response
            location = _header(response.headers, "Location")
            if not location or not _safe_redirect(location):
                raise LogFetchError("GitHub returned an invalid log-download redirect")
            # Signed blob-storage URLs are fetched without the GitHub bearer token.
            url = location
            headers = {"Accept": "application/octet-stream"}
        raise LogFetchError("Too many redirects while downloading job logs")

    def _download(self, repository: str, job_id: int, deadline: float) -> bytes:
        owner, name = repository.split("/", 1)
        url = f"{API_ROOT}/repos/{owner}/{name}/actions/jobs/{job_id}/logs"
        response = self._get_with_redirects(url, authenticated=True, deadline=deadline)
        if response.status in (200, 206):
            if len(response.body) > self._max_bytes:
                raise LogFetchError("Job logs exceeded the configured response-size limit")
            if not response.body:
                raise LogFetchError("GitHub returned an empty job-log response")
            return response.body
        if response.status in (404, 410):
            raise LogFetchError(f"Job logs are unavailable or expired (HTTP {response.status})")
        if response.status == 403:
            remaining = _header(response.headers, "X-RateLimit-Remaining")
            if remaining == "0" or _header(response.headers, "Retry-After"):
                raise _TransientHttpError(response.status, response.headers)
            raise LogFetchError("GitHub denied access to the job logs (HTTP 403)")
        if response.status in (202, 429) or response.status >= 500:
            raise _TransientHttpError(response.status, response.headers)
        raise LogFetchError(f"GitHub job-log request failed (HTTP {response.status})")

    def fetch(self, repository: str, job_id: int) -> bytes:
        if not isinstance(repository, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise LogFetchError("repository must be a valid owner/name identifier")
        if not isinstance(job_id, int) or isinstance(job_id, bool) or job_id <= 0:
            raise LogFetchError("job_id must be a positive integer")
        deadline = self._clock() + self._deadline_seconds
        last_error = "unknown error"
        for attempt in range(self._max_attempts):
            try:
                return self._download(repository, job_id, deadline)
            except _TransientHttpError as exc:
                last_error = f"transient GitHub HTTP {exc.status}"
                delay = self._retry_after(exc.headers, wall_clock=self._wall_clock)
            except (TimeoutError, URLError, OSError) as exc:
                last_error = type(exc).__name__
                delay = None
            except LogFetchError:
                raise
            if attempt + 1 >= self._max_attempts:
                break
            remaining = deadline - self._clock()
            if remaining <= 0:
                break
            if delay is None:
                delay = min(self._initial_backoff * (2 ** attempt), self._max_backoff)
            if delay >= remaining:
                break
            self._sleep(delay)
        raise LogFetchError(f"Log-fetch cycle stopped after its bounded retry budget ({last_error})")

    @staticmethod
    def _retry_after(headers: Mapping[str, str], *,
                     wall_clock: Callable[[], float] = time.time) -> float | None:
        value = _header(headers, "Retry-After")
        if value:
            try:
                return max(0.0, min(float(value), 300.0))
            except ValueError:
                try:
                    retry_at = parsedate_to_datetime(value)
                    if retry_at.tzinfo is None:
                        retry_at = retry_at.replace(tzinfo=timezone.utc)
                    return max(0.0, min(retry_at.timestamp() - wall_clock(), 300.0))
                except (TypeError, ValueError, OverflowError):
                    pass
        reset = _header(headers, "X-RateLimit-Reset")
        if reset and _header(headers, "X-RateLimit-Remaining") == "0":
            try:
                return max(0.0, min(float(reset) - wall_clock() + 2, 300.0))
            except ValueError:
                pass
        return None


class _TransientHttpError(Exception):
    def __init__(self, status: int, headers: Mapping[str, str]):
        super().__init__(f"transient HTTP {status}")
        self.status = status
        self.headers = headers


def _cache_key(repository: str, job_id: int) -> str:
    return hashlib.sha256(f"{repository}:{job_id}".encode()).hexdigest()


def _load_state(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(value, dict) and value.get("version") == 1 and isinstance(value.get("entries"), dict):
            return value
    except (OSError, json.JSONDecodeError):
        pass
    return {"version": 1, "entries": {}}


def _atomic_write(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=".log-fetch-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def fetch_cached_job_logs(fetcher: GitHubJobLogFetcher, repository: str, job_id: int,
                          state_file: Path, cache_dir: Path, *,
                          cache_ttl_seconds: int = DEFAULT_CACHE_TTL_SECONDS,
                          wall_clock: Callable[[], float] = time.time) -> tuple[bytes, str]:
    key = _cache_key(repository, job_id)
    state = _load_state(state_file)
    entry = state["entries"].get(key, {})
    cache_path = cache_dir / f"{key}.log"
    if isinstance(entry, dict):
        try:
            age = wall_clock() - float(entry.get("fetched_at", 0))
            if 0 <= age <= cache_ttl_seconds and entry.get("status") == "unavailable":
                raise LogFetchError(
                    "a prior bounded fetch cycle marked this job unavailable; refusing a repeat fetch"
                )
            if 0 <= age <= cache_ttl_seconds and entry.get("status") == "success":
                cached = cache_path.read_bytes()
                digest = hashlib.sha256(cached).hexdigest()
                if digest == entry.get("sha256"):
                    return cached, "cache-hit"
        except (OSError, TypeError, ValueError):
            pass

    try:
        content = fetcher.fetch(repository, job_id)
    except LogFetchError:
        # Negative-cache the bounded outcome so another diagnostic branch in
        # the same run cannot immediately repeat the same failed request.
        try:
            state["entries"][key] = {"status": "unavailable", "sha256": None, "fetched_at": wall_clock()}
            _atomic_write(state_file, json.dumps(state, sort_keys=True).encode("utf-8"))
        except OSError as exc:
            print(f"[log-fetch] warning: could not persist unavailable outcome ({type(exc).__name__})", file=sys.stderr)
        raise
    digest = hashlib.sha256(content).hexdigest()
    try:
        cache_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(cache_dir, 0o700)
        _atomic_write(cache_path, content)
        state["entries"][key] = {"status": "success", "sha256": digest, "fetched_at": wall_clock()}
        _atomic_write(state_file, json.dumps(state, sort_keys=True).encode("utf-8"))
    except OSError as exc:
        print(f"[log-fetch] warning: fetched logs but could not persist cache ({type(exc).__name__})", file=sys.stderr)
    return content, "fetched"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--job-id", required=True, type=int)
    parser.add_argument("--state-file", type=Path, required=True)
    parser.add_argument("--cache-dir", type=Path, required=True)
    parser.add_argument("--max-attempts", type=int, default=DEFAULT_MAX_ATTEMPTS)
    parser.add_argument("--deadline-seconds", type=int, default=DEFAULT_DEADLINE_SECONDS)
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    args = parser.parse_args(argv)
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    try:
        fetcher = GitHubJobLogFetcher(
            token or "", max_attempts=args.max_attempts,
            deadline_seconds=args.deadline_seconds, max_bytes=args.max_bytes,
        )
        content, result = fetch_cached_job_logs(
            fetcher, args.repository, args.job_id, args.state_file, args.cache_dir
        )
        print(f"[log-fetch] {result} job={args.job_id} bytes={len(content)} sha256={hashlib.sha256(content).hexdigest()}", file=sys.stderr)
        sys.stdout.buffer.write(content)
        return 0
    except LogFetchError as exc:
        print(f"[log-fetch] unavailable: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
