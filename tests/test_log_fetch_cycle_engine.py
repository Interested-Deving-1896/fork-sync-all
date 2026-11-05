"""Tests for the bounded GitHub Actions log-fetch cycle engine."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pytest

from scripts.log_fetch_cycle_engine import (
    GitHubJobLogFetcher,
    HttpResponse,
    LogFetchError,
    fetch_cached_job_logs,
)


class FakeTransport:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def get(self, url, headers, timeout, max_bytes):
        self.calls.append((url, dict(headers), timeout, max_bytes))
        item = self.responses.pop(0)
        if isinstance(item, Exception):
            raise item
        return item


def make_fetcher(transport, sleeps=None, **kwargs):
    return GitHubJobLogFetcher(
        "secret-token",
        transport=transport,
        sleeper=(sleeps if sleeps is not None else lambda _seconds: None),
        **kwargs,
    )


def redirect(location="https://logs.example.invalid/signed"):
    return HttpResponse(302, {"Location": location}, b"")


def test_successful_redirect_does_not_forward_bearer_token():
    transport = FakeTransport([redirect(), HttpResponse(200, {}, b"linker error")])
    content = make_fetcher(transport).fetch("owner/repo", 42)
    assert content == b"linker error"
    assert transport.calls[0][1]["Authorization"] == "Bearer secret-token"
    assert "Authorization" not in transport.calls[1][1]


def test_transient_500_retries_with_bounded_backoff():
    transport = FakeTransport([
        HttpResponse(500, {}, b""),
        redirect(),
        HttpResponse(200, {}, b"ok"),
    ])
    sleeps = []
    content = make_fetcher(transport, sleeps.append, max_attempts=3).fetch("owner/repo", 42)
    assert content == b"ok"
    assert sleeps == [2]
    assert len(transport.calls) == 3


def test_rate_limit_retry_after_is_respected_and_capped():
    transport = FakeTransport([
        HttpResponse(429, {"Retry-After": "7"}, b""),
        redirect(),
        HttpResponse(200, {}, b"ok"),
    ])
    sleeps = []
    make_fetcher(transport, sleeps.append).fetch("owner/repo", 42)
    assert sleeps == [7]


def test_terminal_404_is_not_retried():
    transport = FakeTransport([HttpResponse(404, {}, b"")])
    with pytest.raises(LogFetchError, match="unavailable or expired"):
        make_fetcher(transport).fetch("owner/repo", 42)
    assert len(transport.calls) == 1


def test_invalid_redirect_is_rejected_without_second_request():
    transport = FakeTransport([redirect("http://insecure.example/logs")])
    with pytest.raises(LogFetchError, match="invalid log-download redirect"):
        make_fetcher(transport).fetch("owner/repo", 42)
    assert len(transport.calls) == 1


def test_oversized_logs_are_rejected():
    transport = FakeTransport([redirect(), HttpResponse(200, {}, b"x" * 2048)])
    with pytest.raises(LogFetchError, match="response-size limit"):
        make_fetcher(transport, max_bytes=1024).fetch("owner/repo", 42)


def test_successful_logs_are_cached_and_verified(tmp_path: Path):
    state = tmp_path / "state.json"
    cache = tmp_path / "cache"
    transport = FakeTransport([redirect(), HttpResponse(200, {}, b"original")])
    fetcher = make_fetcher(transport)

    first, status = fetch_cached_job_logs(fetcher, "owner/repo", 42, state, cache)
    second, status2 = fetch_cached_job_logs(fetcher, "owner/repo", 42, state, cache)

    assert first == second == b"original"
    assert status == "fetched"
    assert status2 == "cache-hit"
    assert len(transport.calls) == 2
    data = json.loads(state.read_text())
    assert data["entries"][hashlib.sha256(b"owner/repo:42").hexdigest()]["sha256"] == hashlib.sha256(b"original").hexdigest()


def test_corrupt_cache_is_refetched(tmp_path: Path):
    state = tmp_path / "state.json"
    cache = tmp_path / "cache"
    transport = FakeTransport([redirect(), HttpResponse(200, {}, b"original"), redirect(), HttpResponse(200, {}, b"fresh")])
    fetcher = make_fetcher(transport)
    fetch_cached_job_logs(fetcher, "owner/repo", 42, state, cache)
    next(cache.glob("*.log")).write_bytes(b"tampered")
    content, status = fetch_cached_job_logs(fetcher, "owner/repo", 42, state, cache)
    assert content == b"fresh"
    assert status == "fetched"
    assert len(transport.calls) == 4


def test_cache_does_not_store_token_or_log_body_in_state(tmp_path: Path):
    state = tmp_path / "state.json"
    cache = tmp_path / "cache"
    transport = FakeTransport([redirect(), HttpResponse(200, {}, b"private-log-content")])
    fetch_cached_job_logs(make_fetcher(transport), "owner/repo", 42, state, cache)
    text = state.read_text()
    assert "secret-token" not in text
    assert "private-log-content" not in text


def test_attempt_budget_is_hard_bounded():
    transport = FakeTransport([HttpResponse(503, {}, b"")] * 10)
    with pytest.raises(LogFetchError, match="bounded retry budget"):
        make_fetcher(transport, max_attempts=2).fetch("owner/repo", 42)
    assert len(transport.calls) == 2


def test_invalid_job_id_is_rejected_before_network():
    transport = FakeTransport([])
    with pytest.raises(LogFetchError, match="positive integer"):
        make_fetcher(transport).fetch("owner/repo", 0)
    assert transport.calls == []

def test_deadline_prevents_sleep_beyond_remaining_budget():
    transport = FakeTransport([HttpResponse(503, {}, b"")])
    sleeps = []
    with pytest.raises(LogFetchError, match="bounded retry budget"):
        make_fetcher(
            transport, sleeps.append, max_attempts=5, deadline_seconds=2,
            initial_backoff=2, max_backoff=2,
        ).fetch("owner/repo", 42)
    assert sleeps == []
    assert len(transport.calls) == 1


def test_resolver_uses_one_shared_engine_instead_of_direct_log_curl():
    resolver = (Path(__file__).resolve().parents[1] / "scripts/resolve-failures.sh").read_text()
    assert "log_fetch_cycle_engine.py" in resolver
    assert "LOG_FETCH_STATE_FILE" in resolver
    assert 'actions/jobs/${job_id}/logs' not in resolver

def test_invalid_repository_is_rejected_before_network():
    transport = FakeTransport([])
    with pytest.raises(LogFetchError, match="owner/name"):
        make_fetcher(transport).fetch("owner/repo/extra", 42)
    assert transport.calls == []

def test_unavailable_outcome_is_negative_cached_for_the_run(tmp_path: Path):
    state = tmp_path / "state.json"
    cache = tmp_path / "cache"
    transport = FakeTransport([HttpResponse(404, {}, b"")])
    fetcher = make_fetcher(transport)

    with pytest.raises(LogFetchError, match="unavailable or expired"):
        fetch_cached_job_logs(fetcher, "owner/repo", 42, state, cache)
    with pytest.raises(LogFetchError, match="refusing a repeat fetch"):
        fetch_cached_job_logs(fetcher, "owner/repo", 42, state, cache)

    assert len(transport.calls) == 1
    entry = next(iter(json.loads(state.read_text())["entries"].values()))
    assert entry["status"] == "unavailable"
    assert entry["sha256"] is None



def test_http_date_retry_after_uses_injected_wall_clock():
    from email.utils import formatdate

    transport = FakeTransport([
        HttpResponse(429, {"Retry-After": formatdate(1010, usegmt=True)}, b""),
        redirect(),
        HttpResponse(200, {}, b"ok"),
    ])
    sleeps = []
    fetcher = make_fetcher(
        transport, sleeps.append, wall_clock=lambda: 1000.0,
    )
    assert fetcher.fetch("owner/repo", 42) == b"ok"
    assert sleeps == [10.0]


def test_rate_limit_reset_uses_injected_wall_clock():
    transport = FakeTransport([
        HttpResponse(403, {
            "X-RateLimit-Remaining": "0",
            "X-RateLimit-Reset": "1100",
        }, b""),
        redirect(),
        HttpResponse(200, {}, b"ok"),
    ])
    sleeps = []
    fetcher = make_fetcher(
        transport, sleeps.append, deadline_seconds=150, wall_clock=lambda: 1000.0,
    )
    assert fetcher.fetch("owner/repo", 42) == b"ok"
    assert sleeps == [102.0]


def test_retry_wait_longer_than_remaining_deadline_is_not_slept():
    transport = FakeTransport([
        HttpResponse(429, {"Retry-After": "30"}, b""),
    ])
    sleeps = []
    fetcher = make_fetcher(
        transport, sleeps.append, max_attempts=5, deadline_seconds=2,
        clock=lambda: 100.0, wall_clock=lambda: 1000.0,
    )
    with pytest.raises(LogFetchError, match="bounded retry budget"):
        fetcher.fetch("owner/repo", 42)
    assert sleeps == []
    assert len(transport.calls) == 1
