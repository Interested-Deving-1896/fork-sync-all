"""Regression checks for the rolling pipeline-telemetry issue upsert."""

import json
import re
import subprocess
import sys
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


def _rolling_report_python():
    match = re.search(
        r'ISSUE_BODY=\$\(python3 - "\$RECENT_RUNS_FILE" "\$ISSUE_WINDOW_DAYS" "\$REPO" <<\'PYEOF\'\n(.*?)\nPYEOF',
        SCRIPT,
        re.DOTALL,
    )
    assert match, "could not locate the rolling-report Python program"
    return match.group(1)


def test_oversized_payload_is_parsed_at_runtime_from_file(tmp_path):
    # ~2 MB of JSON: intentionally larger than common OS argv limits.
    run = {
        "name": "Repeated workflow",
        "conclusion": "success",
        "run_started_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:01:00Z",
        "padding": "x" * 64,
    }
    payload = json.dumps([run] * 25000)
    assert len(payload) > 1_500_000
    payload_file = tmp_path / "recent-runs.json"
    payload_file.write_text(payload, encoding="utf-8")

    result = subprocess.run(
        [sys.executable, "-c", _rolling_report_python(), str(payload_file), "30", "owner/repo"],
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert "<!-- pipeline-telemetry-report -->" in result.stdout
    assert "25000 runs across 1 workflows" in result.stdout


def test_malformed_payload_fails_without_producing_report(tmp_path):
    payload_file = tmp_path / "malformed-runs.json"
    payload_file.write_text('{"workflow_runs": [', encoding="utf-8")

    result = subprocess.run(
        [sys.executable, "-c", _rolling_report_python(), str(payload_file), "30", "owner/repo"],
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode != 0
    assert result.stdout == ""
