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


def test_rolling_metrics_pagination_is_capped_at_200_runs():
    assert "if len(batch) < 100 or page >= 2:" in SCRIPT
    assert "up to 200, paginated" in SCRIPT


def _rolling_runs_python():
    marker = "if ! RECENT_RUNS=$(python3 - \"$REPO\" \"$API\" \"$GH_TOKEN\" \"$WINDOW_START\" <<'PYEOF'\n"
    return SCRIPT.split(marker, 1)[1].split("\nPYEOF", 1)[0]


def _run_rolling_runs_python(monkeypatch, urlopen):
    import sys
    import urllib.request

    monkeypatch.setattr(sys, "argv", [
        "telemetry-fetch", "owner/repo", "https://api.github.com",
        "test-token", "2026-01-01T00:00:00Z",
    ])
    monkeypatch.setattr(urllib.request, "urlopen", urlopen)
    exec(compile(_rolling_runs_python(), "<rolling-runs>", "exec"), {})


def test_rolling_metrics_runtime_stops_after_two_full_pages(monkeypatch, capsys):
    import io
    import json

    requested_urls = []

    def fake_urlopen(request, timeout):
        requested_urls.append(request.full_url)
        page = len(requested_urls)
        payload = {"workflow_runs": [{"id": (page - 1) * 100 + i} for i in range(100)]}
        return io.BytesIO(json.dumps(payload).encode())

    _run_rolling_runs_python(monkeypatch, fake_urlopen)

    output = capsys.readouterr()
    assert len(requested_urls) == 2
    assert "page=1" in requested_urls[0]
    assert "page=2" in requested_urls[1]
    assert len(json.loads(output.out)) == 200


def test_rolling_metrics_runtime_fails_closed_if_second_page_fails(monkeypatch, capsys):
    import io
    import json
    import sys
    import urllib.error

    requested_urls = []

    def fake_urlopen(request, timeout):
        requested_urls.append(request.full_url)
        if len(requested_urls) == 2:
            raise urllib.error.URLError("simulated page-two outage")
        payload = {"workflow_runs": [{"id": i} for i in range(100)]}
        return io.BytesIO(json.dumps(payload).encode())

    try:
        _run_rolling_runs_python(monkeypatch, fake_urlopen)
        assert False, "pagination failure should exit non-zero"
    except SystemExit as exc:
        assert exc.code == 1

    output = capsys.readouterr()
    assert len(requested_urls) == 2
    assert output.out == ""
    assert "page 2" in output.err


def test_rolling_metrics_payload_is_not_passed_through_argv() -> None:
    # SCRIPT is already loaded as text at module import time. Scope the argv
    # assertion to the rolling-payload generator, not unrelated helpers above.
    script = SCRIPT
    marker = "# Keep the JSON payload out of argv:"
    assert marker in script
    rolling_payload_block = script[script.index(marker):]
    assert 'RECENT_RUNS_FILE=$(mktemp' in rolling_payload_block
    assert 'with open(sys.argv[1], encoding="utf-8") as payload_file:' in rolling_payload_block
    assert 'json.loads(sys.argv[1])' not in rolling_payload_block
    assert 'rm -f "$RECENT_RUNS_FILE"' in rolling_payload_block


def test_rolling_metrics_runtime_encodes_created_filter(monkeypatch, capsys):
    import io
    import json
    import urllib.parse

    requested_urls = []

    def fake_urlopen(request, timeout):
        requested_urls.append(request.full_url)
        return io.BytesIO(json.dumps({"workflow_runs": [{"id": 42}]}).encode())

    _run_rolling_runs_python(monkeypatch, fake_urlopen)

    output = capsys.readouterr()
    assert len(json.loads(output.out)) == 1
    query = urllib.parse.parse_qs(urllib.parse.urlparse(requested_urls[0]).query)
    assert query["created"] == [">=2026-01-01T00:00:00Z"]
    assert query["status"] == ["completed"]
    assert query["page"] == ["1"]


def test_rolling_metrics_runtime_fails_closed_on_invalid_response_shape(monkeypatch, capsys):
    import io
    import json

    def fake_urlopen(request, timeout):
        return io.BytesIO(json.dumps({"workflow_runs": None}).encode())

    try:
        _run_rolling_runs_python(monkeypatch, fake_urlopen)
        assert False, "invalid response shape should exit non-zero"
    except SystemExit as exc:
        assert exc.code == 1

    output = capsys.readouterr()
    assert output.out == ""
    assert "invalid completed workflow runs response on page 1" in output.err


def test_rolling_metrics_runtime_fails_closed_on_malformed_json(monkeypatch, capsys):
    import io

    def fake_urlopen(request, timeout):
        return io.BytesIO(b"{not valid JSON")

    try:
        _run_rolling_runs_python(monkeypatch, fake_urlopen)
        assert False, "malformed JSON should exit non-zero"
    except SystemExit as exc:
        assert exc.code == 1

    output = capsys.readouterr()
    assert output.out == ""
    assert "page 1" in output.err
