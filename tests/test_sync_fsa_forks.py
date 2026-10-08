"""Behavioral regression coverage for downstream FSA PR synchronization."""

import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SYNC_SCRIPT = ROOT / "scripts/sync-fsa-forks.sh"


def run_sync(tmp_path: Path, scenario: str) -> subprocess.CompletedProcess[str]:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    call_log = tmp_path / "curl-calls.log"
    fake_curl = fake_bin / "curl"
    fake_curl.write_text(
        r'''#!/usr/bin/env bash
set -euo pipefail
method=GET
url=""
while (( $# > 0 )); do
  case "$1" in
    -X)
      shift
      method="$1"
      ;;
    -D)
      shift
      : > "$1"
      ;;
    https://api.github.com/*)
      url="$1"
      ;;
  esac
  shift
done
printf '%s %s\n' "$method" "$url" >> "$CALL_LOG"

body='{}'
code=200
case "$url" in
  */repos/Interested-Deving-1896/fork-sync-all/commits/main)
    body='{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
    ;;
  */repos/OpenOS-Project-OSP/fork-sync-all/commits/main)
    body='{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
    ;;
  */compare/*)
    body='{"status":"ahead","ahead_by":2}'
    ;;
  *'/pulls?'*)
    if [[ "$TEST_SCENARIO" == "preexisting" ]]; then
      body='[{"number":8,"html_url":"https://github.com/OpenOS-Project-OSP/fork-sync-all/pull/8"}]'
    else
      body='[]'
    fi
    ;;
  */pulls)
    case "$TEST_SCENARIO" in
      create_race)
        code=422
        body='{"message":"Validation Failed","errors":[{"resource":"PullRequest","code":"custom","message":"A pull request already exists for Interested-Deving-1896:main."}]}'
        ;;
      real_error)
        code=422
        body='{"message":"Validation Failed","errors":[{"resource":"PullRequest","code":"custom","message":"No commits between main and main"}]}'
        ;;
      *)
        code=201
        body='{"number":9,"html_url":"https://github.com/OpenOS-Project-OSP/fork-sync-all/pull/9"}'
        ;;
    esac
    ;;
esac
printf '%s\n%s\n' "$body" "$code"
'''
    )
    fake_curl.chmod(0o755)

    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{fake_bin}:{env['PATH']}",
            "CALL_LOG": str(call_log),
            "TEST_SCENARIO": scenario,
            "GH_TOKEN": "test-token",
            "SYNC_TOKEN": "test-token",
            "FORK_FILTER": "OpenOS-Project-OSP/fork-sync-all",
        }
    )
    result = subprocess.run(
        ["bash", str(SYNC_SCRIPT)],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    result.call_log = call_log.read_text()  # type: ignore[attr-defined]
    return result


def test_existing_open_pr_is_an_idempotent_success(tmp_path: Path) -> None:
    result = run_sync(tmp_path, "preexisting")

    assert result.returncode == 0, result.stderr
    assert "PR already open for OSP mirror: #8" in result.stderr
    assert "POST https://api.github.com/repos/OpenOS-Project-OSP/fork-sync-all/pulls" not in result.call_log  # type: ignore[attr-defined]
    assert "errors:0" in result.stderr


def test_duplicate_pr_create_race_is_an_idempotent_success(tmp_path: Path) -> None:
    result = run_sync(tmp_path, "create_race")

    assert result.returncode == 0, result.stderr
    assert "PR already open for OSP mirror" in result.stderr
    assert "errors:0" in result.stderr


def test_real_pr_creation_error_fails_the_script(tmp_path: Path) -> None:
    result = run_sync(tmp_path, "real_error")

    assert result.returncode == 1
    assert "failed to open PR on OSP mirror" in result.stderr
    assert "No commits between main and main" in result.stderr
    assert "errors:1" in result.stderr
