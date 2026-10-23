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


def test_run_inventory_uses_encoded_created_filter_and_fails_closed():
    assert "urllib.parse.urlencode({" in SCRIPT
    assert "'created': f'>={since}'" in SCRIPT
    assert "failed to fetch completed runs (page" in SCRIPT
    assert "invalid completed-runs response on page" in SCRIPT
    assert "Could not fetch the complete rolling run inventory" in SCRIPT
    assert "refusing to publish potentially false zero-run metrics" in SCRIPT


# Execute the embedded inventory-fetcher with mocked HTTP, rather than only
# asserting that particular source strings are present.
import contextlib
import io
import json
import re
import sys
import urllib.parse
import urllib.request
from unittest.mock import patch


def _inventory_python_block():
    match = re.search(
        r'RECENT_RUNS=\$\(python3 - "\$REPO" "\$API" "\$GH_TOKEN" '
        r'"\$WINDOW_START" <<\'PYEOF\'\n(.*?)\nPYEOF',
        SCRIPT,
        re.DOTALL,
    )
    assert match, "could not locate embedded run-inventory Python block"
    return match.group(1)


def _run_inventory(responses, *, side_effect=None):
    block = _inventory_python_block()
    stdout = io.StringIO()
    stderr = io.StringIO()
    calls = []

    def fake_urlopen(request, timeout=30):
        calls.append((request.full_url, timeout))
        if side_effect is not None:
            raise side_effect
        response = responses.pop(0)
        return io.BytesIO(json.dumps(response).encode("utf-8"))

    with patch.object(sys, "argv", ["inventory.py", "owner/repo", "https://api.github.com", "token", "2026-10-01"]), \
         patch.object(urllib.request, "urlopen", side_effect=fake_urlopen), \
         contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        try:
            exec(compile(block, "pipeline-telemetry-inventory", "exec"), {})
            exit_code = 0
        except SystemExit as exc:
            exit_code = exc.code if isinstance(exc.code, int) else 1
    return exit_code, stdout.getvalue(), stderr.getvalue(), calls


def test_run_inventory_mocked_http_success_encodes_filter():
    code, stdout, stderr, calls = _run_inventory([{"workflow_runs": [{"id": 42}]}])
    assert code == 0
    assert json.loads(stdout) == [{"id": 42}]
    assert not stderr
    query = urllib.parse.parse_qs(urllib.parse.urlparse(calls[0][0]).query)
    assert query["created"] == [">=2026-10-01"]
    assert query["page"] == ["1"]


def test_run_inventory_mocked_http_paginates_until_short_page():
    full_page = [{"id": i} for i in range(100)]
    code, stdout, stderr, calls = _run_inventory([
        {"workflow_runs": full_page},
        {"workflow_runs": [{"id": 100}]},
    ])
    assert code == 0
    assert len(json.loads(stdout)) == 101
    assert len(calls) == 2
    assert urllib.parse.parse_qs(urllib.parse.urlparse(calls[1][0]).query)["page"] == ["2"]


def test_run_inventory_mocked_http_failure_exits_nonzero():
    code, stdout, stderr, calls = _run_inventory([], side_effect=OSError("rate limit"))
    assert code == 1
    assert not stdout
    assert "failed to fetch completed runs (page 1)" in stderr
    assert "rate limit" in stderr


def test_run_inventory_mocked_http_malformed_json_exits_nonzero():
    block = _inventory_python_block()
    stdout, stderr = io.StringIO(), io.StringIO()
    with patch.object(sys, "argv", ["inventory.py", "owner/repo", "https://api.github.com", "token", "2026-10-01"]), \
         patch.object(urllib.request, "urlopen", return_value=io.BytesIO(b"{not-json")), \
         contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        try:
            exec(compile(block, "pipeline-telemetry-inventory", "exec"), {})
            code = 0
        except SystemExit as exc:
            code = exc.code if isinstance(exc.code, int) else 1
    assert code == 1
    assert not stdout
    assert "failed to fetch completed runs (page 1)" in stderr


def test_run_inventory_mocked_http_invalid_shape_exits_nonzero():
    code, stdout, stderr, calls = _run_inventory([{"message": "rate limited"}])
    assert code == 1
    assert not stdout
    assert "invalid completed-runs response on page 1" in stderr
