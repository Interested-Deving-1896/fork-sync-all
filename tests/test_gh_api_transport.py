"""Regression tests for fail-closed handling in scripts/includes/gh-api.sh."""

import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "includes" / "gh-api.sh"


def _run_gh_api(tmp_path: Path, *, curl_exit: int, status: str, body: str = '{"ok":true}') -> subprocess.CompletedProcess[str]:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    curl = fake_bin / "curl"
    curl.write_text(
        "#!/usr/bin/env bash\n"
        'printf "call\\n" >> "$CALL_COUNT_FILE"\n'
        f"printf '%s\\n' {body!r}\n"
        f"printf '%s' {status!r}\n"
        f"exit {curl_exit}\n",
        encoding="utf-8",
    )
    curl.chmod(0o755)
    sleep = fake_bin / "sleep"
    sleep.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    sleep.chmod(0o755)

    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    env["GH_TOKEN"] = "test-token"
    env["CALL_COUNT_FILE"] = str(tmp_path / "curl-calls")
    return subprocess.run(
        [
            "bash",
            "-c",
            f'source "{HELPER}"; gh_api GET "https://api.github.com/test"',
        ],
        env=env,
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )


def test_transport_error_fails_closed(tmp_path: Path) -> None:
    result = _run_gh_api(tmp_path, curl_exit=7, status="000")

    assert result.returncode != 0
    assert "transport failure" in result.stderr
    assert len((tmp_path / "curl-calls").read_text().splitlines()) == 4


def test_http_000_fails_closed_even_if_curl_exits_zero(tmp_path: Path) -> None:
    result = _run_gh_api(tmp_path, curl_exit=0, status="000")

    assert result.returncode != 0
    assert "transport failure" in result.stderr


def test_http_200_returns_body_successfully(tmp_path: Path) -> None:
    result = _run_gh_api(tmp_path, curl_exit=0, status="200")

    assert result.returncode == 0
    assert result.stdout.strip() == '{"ok":true}'


def test_http_500_retries_then_fails(tmp_path: Path) -> None:
    result = _run_gh_api(tmp_path, curl_exit=0, status="500", body='{"error":"upstream"}')

    assert result.returncode != 0
    assert "server error 500" in result.stderr
    # Initial request plus exactly three retries; no unbounded retry loop.
    assert len((tmp_path / "curl-calls").read_text().splitlines()) == 4


def test_rate_limit_retries_are_bounded(tmp_path: Path) -> None:
    result = _run_gh_api(tmp_path, curl_exit=0, status="429", body='{"message":"rate limited"}')

    assert result.returncode != 0
    assert "rate limited" in result.stderr
    assert len((tmp_path / "curl-calls").read_text().splitlines()) == 4


def test_malformed_http_status_fails_closed(tmp_path: Path) -> None:
    result = _run_gh_api(tmp_path, curl_exit=0, status="not-a-status")

    assert result.returncode != 0
    assert "transport failure" in result.stderr


def test_missing_http_status_fails_closed(tmp_path: Path) -> None:
    result = _run_gh_api(tmp_path, curl_exit=0, status="")

    assert result.returncode != 0
    assert "transport failure" in result.stderr


def test_unhandled_client_errors_fail_closed(tmp_path: Path) -> None:
    for status in ("400", "401", "404", "422"):
        case_dir = tmp_path / status
        case_dir.mkdir()
        result = _run_gh_api(case_dir, curl_exit=0, status=status, body='{"error":"request rejected"}')

        assert result.returncode != 0, f"HTTP {status} was incorrectly accepted"
        assert f"HTTP {status}" in result.stderr or status in result.stdout


def test_redirect_is_not_reported_as_success(tmp_path: Path) -> None:
    result = _run_gh_api(tmp_path, curl_exit=0, status="302", body="redirect")

    assert result.returncode != 0
    assert "HTTP 302" in result.stderr
