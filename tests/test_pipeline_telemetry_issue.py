"""Regression checks for the rolling pipeline-telemetry issue upsert."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "scripts/pipeline-telemetry.sh").read_text()
WORKFLOW = (ROOT / ".github/workflows/pipeline-telemetry.yml").read_text()


def test_issue_writes_use_scoped_workflow_token():
    assert "ISSUE_TOKEN: ${{ github.token }}" in WORKFLOW
    assert 'ISSUE_TOKEN="${ISSUE_TOKEN:-$GH_TOKEN}"' in SCRIPT
    assert 'Authorization: Bearer ${ISSUE_TOKEN}' in SCRIPT


def test_empty_existing_report_is_recovered_by_exact_title():
    assert "i.get('title') == sys.argv[1]" in SCRIPT
    assert "'pull_request' not in i" in SCRIPT
    assert "Without the title fallback" in SCRIPT


def test_marker_is_required_before_and_after_issue_mutation():
    marker = "<!-- pipeline-telemetry-report -->"
    assert SCRIPT.count(marker) >= 4
    assert "refusing to mutate GitHub issues" in SCRIPT
    assert "response did not contain the complete rolling report body" in SCRIPT


def test_issue_mutations_fail_loudly_and_send_json():
    assert SCRIPT.count('Content-Type: application/json') >= 3
    assert "GitHub rejected rolling issue update" in SCRIPT
    assert "GitHub rejected rolling issue creation" in SCRIPT


def test_large_run_payload_is_read_from_a_file_not_argv():
    assert 'RECENT_RUNS_FILE=$(mktemp' in SCRIPT
    assert 'printf \'%s\' "$RECENT_RUNS" > "$RECENT_RUNS_FILE"' in SCRIPT
    assert 'runs_raw = json.load(f)' in SCRIPT
    assert 'trap \'rm -f "${RECENT_RUNS_FILE:-}"\' EXIT' in SCRIPT
    assert 'ISSUE_BODY=$(python3 - "$RECENT_RUNS" "$ISSUE_WINDOW_DAYS" "$REPO"' not in SCRIPT
