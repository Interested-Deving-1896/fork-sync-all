"""Focused regression tests for dispatch correlation and full-chain fail-closed behavior."""

import json
import os
from pathlib import Path
import stat
import subprocess


ROOT = Path(__file__).resolve().parents[1]
DISPATCHER = ROOT / "scripts/dispatch-and-wait.sh"
FULL_CHAIN = ROOT / ".github/workflows/full-chain-flush.yml"


FAKE_CURL = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
url = next((arg for arg in args if arg.startswith("https://")), "")
state_path = Path(os.environ["FAKE_CURL_STATE"])
log_path = Path(os.environ["FAKE_CURL_LOG"])
state = json.loads(state_path.read_text()) if state_path.exists() else {
    "dispatches": 0,
    "run_lists": 0,
}

with log_path.open("a") as log:
    log.write(json.dumps({"args": args, "url": url}) + "\n")

def option_value(name):
    try:
        return args[args.index(name) + 1]
    except (ValueError, IndexError):
        return None

def write_output(payload):
    output = option_value("-o")
    if output:
        Path(output).write_text(payload)
    else:
        sys.stdout.write(payload)

if url.endswith("/rate_limit"):
    write_output(json.dumps({"resources": {"core": {"remaining": 5000, "reset": 0}}}))
elif "/dispatches" in url:
    state["dispatches"] += 1
    body_arg = option_value("-d")
    if body_arg and body_arg.startswith("@"):
        with log_path.open("a") as log:
            log.write(json.dumps({"request_body": json.loads(Path(body_arg[1:]).read_text())}) + "\n")
    code = os.environ.get("FAKE_DISPATCH_CODE", "200")
    payload = json.dumps({"workflow_run_id": 4241 + state["dispatches"]}) if code == "200" else ""
    write_output(payload)
    header_output = option_value("-D")
    if header_output:
        Path(header_output).write_text("")
    sys.stdout.write(code)
elif "/actions/workflows/" in url and "/runs?" in url:
    state["run_lists"] += 1
    # First list is the pre-dispatch legacy snapshot. A later list exposes the
    # single newly created run for an HTTP 204 response.
    runs = []
    if os.environ.get("FAKE_DISPATCH_CODE") == "204" and state["run_lists"] > 1:
        runs = [{
            "id": 5252,
            "event": "workflow_dispatch",
            "head_branch": "main",
            "created_at": "2999-01-01T00:00:00Z",
        }]
    write_output(json.dumps({"workflow_runs": runs}))
elif "/actions/runs/" in url:
    run_id = int(url.rsplit("/", 1)[-1])
    cancelled_first = os.environ.get("FAKE_CANCEL_FIRST") == "true" and run_id == 4242
    conclusion = "cancelled" if cancelled_first else "success"
    write_output(json.dumps({"status": "completed", "conclusion": conclusion}))
else:
    write_output("{}")

state_path.write_text(json.dumps(state))
'''


def run_dispatcher(tmp_path: Path, *, code: str = "200", cancel_first: bool = False):
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    curl = fake_bin / "curl"
    curl.write_text(FAKE_CURL)
    curl.chmod(curl.stat().st_mode | stat.S_IXUSR)
    sleep = fake_bin / "sleep"
    sleep.write_text("#!/usr/bin/env bash\nexit 0\n")
    sleep.chmod(sleep.stat().st_mode | stat.S_IXUSR)

    log = tmp_path / "curl.log"
    env = {
        **os.environ,
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "GH_TOKEN": "test-token",
        "REPO": "example/repo",
        "FAKE_CURL_STATE": str(tmp_path / "state.json"),
        "FAKE_CURL_LOG": str(log),
        "FAKE_DISPATCH_CODE": code,
        "FAKE_CANCEL_FIRST": str(cancel_first).lower(),
        "DISPATCH_CANCEL_RETRIES": "1" if cancel_first else "0",
    }
    result = subprocess.run(
        ["bash", str(DISPATCHER), "child.yml", "1", '{"scope":"expected"}'],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    entries = [json.loads(line) for line in log.read_text().splitlines()]
    return result, entries


def test_http_200_uses_exact_returned_run_id_and_current_api_header(tmp_path: Path) -> None:
    result, entries = run_dispatcher(tmp_path)

    assert result.returncode == 0, result.stderr
    assert "Dispatched exact run 4242" in result.stderr
    assert "Run ID: 4242" in result.stderr
    calls = [entry for entry in entries if "args" in entry]
    dispatch = next(entry for entry in calls if "/dispatches" in entry["url"])
    assert "X-GitHub-Api-Version: 2026-03-10" in dispatch["args"]
    assert any(entry["url"].endswith("/actions/runs/4242") for entry in calls)
    assert not any(entry["url"].endswith("/actions/runs/5252") for entry in calls)


def test_http_204_legacy_response_correlates_single_new_dispatch(tmp_path: Path) -> None:
    result, entries = run_dispatcher(tmp_path, code="204")

    assert result.returncode == 0, result.stderr
    assert "Legacy HTTP 204 dispatch accepted" in result.stderr
    assert "Run ID: 5252" in result.stderr
    calls = [entry for entry in entries if "args" in entry]
    assert any(entry["url"].endswith("/actions/runs/5252") for entry in calls)


def test_cancelled_run_is_redispatched_once_before_success(tmp_path: Path) -> None:
    result, entries = run_dispatcher(tmp_path, cancel_first=True)

    assert result.returncode == 0, result.stderr
    assert "was cancelled — re-dispatching (1 retries remaining)" in result.stderr
    dispatches = [entry for entry in entries if "/dispatches" in entry.get("url", "")]
    assert len(dispatches) == 2
    assert "Run ID: 4243" in result.stderr


def test_full_chain_supplies_required_inputs_and_fails_closed() -> None:
    workflow = FULL_CHAIN.read_text()

    assert 'DISPATCH_CANCEL_RETRIES: "1"' in workflow
    assert "DISPATCH_CANCEL_EXIT_CODE" not in workflow
    assert "Stage cancelled by queue-manager — continuing." not in workflow
    assert "sync-template.yml 45 '{\"mode\":\"propagate\"}'" in workflow
    assert workflow.count('\"block_on_mismatch\":\"true\"') == 3
    assert '\"block_on_mismatch\":\"false\"' not in workflow
    assert 'post-flush-prep.yml 60 \'{\"repo_filter\":\"\",\"block_on_failure\":\"true\"}\'' in workflow


def test_full_chain_progress_matches_dispatch_count() -> None:
    workflow = FULL_CHAIN.read_text()
    dispatch_count = workflow.count("bash scripts/dispatch-and-wait.sh")

    assert dispatch_count == 46
    assert "number_of_steps: 38" not in workflow
    assert workflow.count(f"number_of_steps: {dispatch_count}") == 26
    assert 'subtitle: "All 46 stages complete"' in workflow
    assert "current_step: 46" in workflow
