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

def test_rolling_metrics_pagination_fails_closed_on_fetch_or_parse_errors():
    assert 'unable to fetch completed workflow runs page {page}' in SCRIPT
    assert 'invalid completed workflow runs response on page {page}' in SCRIPT
    assert 'malformed workflow run record on page {page}' in SCRIPT
    assert 'if ! RECENT_RUNS=$(python3' in SCRIPT
    assert 'refusing to publish incomplete metrics' in SCRIPT
    assert 'except Exception:\n        break' not in SCRIPT
