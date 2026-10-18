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


def test_malformed_http_status_fails_closed(tmp_path: Path) -> None:
    result = _run_gh_api(tmp_path, curl_exit=0, status="not-a-status")

    assert result.returncode != 0
    assert "transport failure" in result.stderr


def test_missing_http_status_fails_closed(tmp_path: Path) -> None:
    result = _run_gh_api(tmp_path, curl_exit=0, status="")

    assert result.returncode != 0
    assert "transport failure" in result.stderr
