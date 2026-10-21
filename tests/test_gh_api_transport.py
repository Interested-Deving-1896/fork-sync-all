"""Executable retry-contract tests for scripts/includes/gh-api.sh."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "includes" / "gh-api.sh"


def _run_gh_api(tmp_path: Path, mode: str) -> subprocess.CompletedProcess[str]:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    count_file = tmp_path / "curl-count"
    count_file.write_text("0", encoding="utf-8")
    curl = fake_bin / "curl"
    curl.write_text(
        """#!/usr/bin/env bash
count=$(cat "$MOCK_CURL_COUNT")
count=$((count + 1))
printf '%s' "$count" > "$MOCK_CURL_COUNT"
header_file=""
while (($#)); do
  if [[ "$1" == "-D" ]]; then
    shift
    header_file="$1"
  fi
  shift
done
case "$MOCK_CURL_MODE" in
  transport) exit 7 ;;
  malformed) printf 'not-json\\nabc'; exit 0 ;;
  server) printf 'server-error\\n503'; exit 0 ;;
  rate_then_success)
    if (( count == 1 )); then
      [[ -z "$header_file" ]] || printf 'X-RateLimit-Reset: 1\\r\\n' > "$header_file"
      printf '{"message":"rate limited"}\\n403'
    else
      printf '{"ok":true}\\n200'
    fi
    exit 0
    ;;
  success) printf '{"ok":true}\\n200'; exit 0 ;;
  zero) printf '{"ok":true}\\n000'; exit 0 ;;
  client_error) printf '{"error":"rejected"}\\n401'; exit 0 ;;
  client_400) printf '{"error":"rejected"}\\n400'; exit 0 ;;
  client_404) printf '{"error":"rejected"}\\n404'; exit 0 ;;
  client_422) printf '{"error":"rejected"}\\n422'; exit 0 ;;
  missing) printf '{"ok":true}'; exit 0 ;;
  redirect) printf 'redirect\\n302'; exit 0 ;;
esac
exit 99
""",
        encoding="utf-8",
    )
    curl.chmod(0o755)
    sleep = fake_bin / "sleep"
    sleep.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    sleep.chmod(0o755)

    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{fake_bin}:{env.get('PATH', '')}",
            "GH_TOKEN": "test-token",
            "MOCK_CURL_MODE": mode,
            "MOCK_CURL_COUNT": str(count_file),
        }
    )
    return subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; gh_api GET "https://api.github.com/test"',
            "_",
            str(HELPER),
        ],
        env=env,
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )


def _calls(tmp_path: Path) -> int:
    return int((tmp_path / "curl-count").read_text(encoding="utf-8"))


def test_transport_failure_retries_then_fails_closed(tmp_path: Path) -> None:
    result = _run_gh_api(tmp_path, "transport")
    assert result.returncode != 0
    assert "transport failure" in result.stderr
    assert _calls(tmp_path) == 4  # initial attempt plus three retries


def test_malformed_http_status_retries_then_fails_closed(tmp_path: Path) -> None:
    result = _run_gh_api(tmp_path, "malformed")
    assert result.returncode != 0
    assert "transport failure" in result.stderr
    assert _calls(tmp_path) == 4


def test_http_5xx_retries_are_bounded(tmp_path: Path) -> None:
    result = _run_gh_api(tmp_path, "server")
    assert result.returncode != 0
    assert _calls(tmp_path) == 4


def test_rate_limit_response_retries_and_can_succeed(tmp_path: Path) -> None:
    result = _run_gh_api(tmp_path, "rate_then_success")
    assert result.returncode == 0, result.stderr
    assert '{"ok":true}' in result.stdout
    assert _calls(tmp_path) == 2


def test_successful_response_is_not_retried(tmp_path: Path) -> None:
    result = _run_gh_api(tmp_path, "success")
    assert result.returncode == 0, result.stderr
    assert '{"ok":true}' in result.stdout
    assert _calls(tmp_path) == 1



def test_http_000_fails_closed(tmp_path: Path) -> None:
    result = _run_gh_api(tmp_path, "zero")
    assert result.returncode != 0
    assert "transport failure" in result.stderr
    assert _calls(tmp_path) == 4


def test_unhandled_client_error_fails_closed(tmp_path: Path) -> None:
    result = _run_gh_api(tmp_path, "client_error")
    assert result.returncode != 0
    assert "HTTP 401" in result.stderr or "401" in result.stdout
    assert _calls(tmp_path) == 1


def test_redirect_is_not_reported_as_success(tmp_path: Path) -> None:
    result = _run_gh_api(tmp_path, "redirect")
    assert result.returncode != 0
    assert "HTTP 302" in result.stderr
    assert _calls(tmp_path) == 1



def test_missing_http_status_fails_closed_after_bounded_retries(tmp_path: Path) -> None:
    result = _run_gh_api(tmp_path, "missing")
    assert result.returncode != 0
    assert "transport failure" in result.stderr
    assert _calls(tmp_path) == 4


def test_additional_unhandled_client_errors_fail_closed_without_retry(tmp_path: Path) -> None:
    for mode, status in (("client_400", "400"), ("client_404", "404"), ("client_422", "422")):
        case_dir = tmp_path / status
        case_dir.mkdir()
        result = _run_gh_api(case_dir, mode)
        assert result.returncode != 0, f"HTTP {status} was incorrectly accepted"
        assert f"HTTP {status}" in result.stderr or status in result.stdout
        assert _calls(case_dir) == 1
