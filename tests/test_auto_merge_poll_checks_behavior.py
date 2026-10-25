"""Behavioral tests for the direct-poll auto-merge check gate.

The production script performs network/API setup at top level, so these tests
extract only _poll_checks_state and provide a deterministic mocked gh_get.
No GitHub API calls or merge commands are executed.
"""

import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "auto-merge-prs.sh"


def _run_gate(*, status=None, checks1=None, checks2=None, fail_url="") -> str:
    script = SCRIPT.read_text(encoding="utf-8")
    start = script.index("_poll_checks_state() {")
    end = script.index("\n# _merge_poll", start)
    function = script[start:end]
    env = os.environ.copy()
    env.update(
        {
            "MOCK_PR": '{"head":{"sha":"' + "a" * 40 + '"}}',
            "MOCK_STATUS": status if status is not None else '{"state":"success","statuses":[{"state":"success"}]}',
            "MOCK_CHECKS1": checks1 if checks1 is not None else '{"check_runs":[{"conclusion":"success"}]}',
            "MOCK_CHECKS2": checks2 if checks2 is not None else '{"check_runs":[]}',
            "MOCK_FAIL_URL": fail_url,
        }
    )
    harness = r'''
gh_get() {
  local url="$1"
  [[ -n "$MOCK_FAIL_URL" && "$url" == *"$MOCK_FAIL_URL"* ]] && return 1
  case "$url" in
    */pulls/1) printf '%s' "$MOCK_PR" ;;
    */commits/*/status) printf '%s' "$MOCK_STATUS" ;;
    *check-runs*page=1*) printf '%s' "$MOCK_CHECKS1" ;;
    *check-runs*page=2*) printf '%s' "$MOCK_CHECKS2" ;;
    *) return 1 ;;
  esac
}
''' + function + r'''
_poll_checks_state 1
'''
    result = subprocess.run(
        ["bash", "-c", harness],
        env=env,
        text=True,
        capture_output=True,
        check=False,
        timeout=5,
    )
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def test_success_requires_green_status_and_check_runs() -> None:
    assert _run_gate() == "success"


def test_pending_legacy_status_blocks_merge() -> None:
    assert _run_gate(status='{"state":"pending","statuses":[{"state":"pending"}]}') == "pending"


def test_pending_combined_status_with_no_legacy_statuses_uses_check_runs() -> None:
    assert _run_gate(
        status='{"state":"pending","statuses":[]}',
        checks1='{"check_runs":[{"conclusion":"success"}]}',
    ) == "success"


def test_failed_combined_status_blocks_merge() -> None:
    assert _run_gate(status='{"state":"failure","statuses":[{"state":"failure"}]}') == "failure"


def test_malformed_combined_status_fails_closed() -> None:
    assert _run_gate(status='{"state":"success","statuses":null}') == "error"


def test_api_error_fails_closed() -> None:
    assert _run_gate(fail_url="/status") == "error"


def test_incomplete_check_run_blocks_merge() -> None:
    assert _run_gate(checks1='{"check_runs":[{"conclusion":null}]}') == "pending"


def test_failed_check_run_blocks_merge() -> None:
    assert _run_gate(checks1='{"check_runs":[{"conclusion":"failure"}]}') == "failure"


def test_all_pages_must_be_successful() -> None:
    page_one = '{"check_runs":[' + ",".join(
        '{"conclusion":"success"}' for _ in range(100)
    ) + ']}'
    assert _run_gate(
        checks1=page_one,
        checks2='{"check_runs":[{"conclusion":"success"}]}',
    ) == "success"


def test_second_page_failure_blocks_merge() -> None:
    page_one = '{"check_runs":[' + ",".join(
        '{"conclusion":"success"}' for _ in range(100)
    ) + ']}'
    assert _run_gate(
        checks1=page_one,
        checks2='{"check_runs":[{"conclusion":"failure"}]}',
    ) == "failure"
