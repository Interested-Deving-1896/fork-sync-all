"""Focused regression tests for dispatch correlation and full-chain fail-closed behavior."""

import json
import os
from pathlib import Path
import stat
import subprocess

import yaml


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
    if os.environ.get("FAKE_ADOPT_ACTIVE") == "true":
        runs = [{
            "id": 7777,
            "event": "workflow_dispatch",
            "head_branch": "main",
            "created_at": "2999-01-01T00:00:00Z",
        }]
    elif os.environ.get("FAKE_DISPATCH_CODE") == "204" and state["run_lists"] > 1:
        runs = [{
            "id": 5252,
            "event": "workflow_dispatch",
            "head_branch": "main",
            "created_at": "2999-01-01T00:00:00Z",
        }]
    write_output(json.dumps({"workflow_runs": runs}))
elif url.endswith("/cancel"):
    write_output("")
    sys.stdout.write("202")
elif "/actions/runs/" in url:
    run_id = int(url.rsplit("/", 1)[-1])
    cancelled_first = os.environ.get("FAKE_CANCEL_FIRST") == "true" and run_id == 4242
    if os.environ.get("FAKE_RUN_IN_PROGRESS") == "true":
        write_output(json.dumps({"status": "in_progress", "conclusion": None}))
    else:
        conclusion = "cancelled" if cancelled_first else "success"
        write_output(json.dumps({"status": "completed", "conclusion": conclusion}))
else:
    write_output("{}")

state_path.write_text(json.dumps(state))
'''


FAKE_DATE = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import sys

if "+%s" in sys.argv:
    state_path = Path(os.environ["FAKE_DATE_STATE"])
    calls = int(state_path.read_text()) if state_path.exists() else 0
    state_path.write_text(str(calls + 1))
    print(1000 if calls == 0 else 1061)
else:
    print("2999-01-01T00:00:01Z")
'''


def run_dispatcher(
    tmp_path: Path,
    *,
    code: str = "200",
    cancel_first: bool = False,
    timeout: str = "1",
    run_in_progress: bool = False,
    force_timeout: bool = False,
    adopt_active: bool = False,
    cancel_adopted: bool = False,
    inputs: str = '{"scope":"expected"}',
):
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    curl = fake_bin / "curl"
    curl.write_text(FAKE_CURL)
    curl.chmod(curl.stat().st_mode | stat.S_IXUSR)
    sleep = fake_bin / "sleep"
    sleep.write_text("#!/usr/bin/env bash\nexit 0\n")
    sleep.chmod(sleep.stat().st_mode | stat.S_IXUSR)
    if force_timeout or adopt_active:
        date = fake_bin / "date"
        date.write_text(FAKE_DATE)
        date.chmod(date.stat().st_mode | stat.S_IXUSR)

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
        "FAKE_RUN_IN_PROGRESS": str(run_in_progress).lower(),
        "FAKE_ADOPT_ACTIVE": str(adopt_active).lower(),
        "FAKE_DATE_STATE": str(tmp_path / "date-state"),
        "DISPATCH_CANCEL_RETRIES": "1" if cancel_first else "0",
        "DISPATCH_CANCEL_ADOPTED_ON_TIMEOUT": str(cancel_adopted).lower(),
    }
    result = subprocess.run(
        ["bash", str(DISPATCHER), "child.yml", timeout, inputs],
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


def test_timeout_cancels_only_the_exact_dispatched_run(tmp_path: Path) -> None:
    result, entries = run_dispatcher(
        tmp_path, timeout="1", run_in_progress=True, force_timeout=True
    )

    assert result.returncode == 1
    assert "Cancellation requested for timed-out run 4242" in result.stderr
    assert "Timed out after 1m waiting for child.yml" in result.stderr
    calls = [entry for entry in entries if "args" in entry]
    cancel_calls = [entry for entry in calls if entry["url"].endswith("/cancel")]
    assert [entry["url"] for entry in cancel_calls] == [
        "https://api.github.com/repos/example/repo/actions/runs/4242/cancel"
    ]


def test_timeout_leaves_adopted_run_active_by_default(tmp_path: Path) -> None:
    result, entries = run_dispatcher(
        tmp_path,
        timeout="1",
        run_in_progress=True,
        force_timeout=True,
        adopt_active=True,
        inputs="{}",
    )

    assert result.returncode == 1
    assert "Found existing in_progress run 7777" in result.stderr
    assert "was adopted, not dispatched by this invocation; leaving it active" in result.stderr
    calls = [entry for entry in entries if "args" in entry]
    assert not any(entry["url"].endswith("/cancel") for entry in calls)
    assert not any("/dispatches" in entry["url"] for entry in calls)


def test_timeout_can_explicitly_cancel_adopted_run(tmp_path: Path) -> None:
    result, entries = run_dispatcher(
        tmp_path,
        timeout="1",
        run_in_progress=True,
        force_timeout=True,
        adopt_active=True,
        cancel_adopted=True,
        inputs="{}",
    )

    assert result.returncode == 1
    assert "Cancellation requested for timed-out run 7777" in result.stderr
    calls = [entry for entry in entries if "args" in entry]
    assert sum(entry["url"].endswith("/runs/7777/cancel") for entry in calls) == 1


def test_timeout_cancellation_option_is_validated(tmp_path: Path) -> None:
    env = {
        **os.environ,
        "GH_TOKEN": "test-token",
        "REPO": "example/repo",
        "DISPATCH_CANCEL_ON_TIMEOUT": "sometimes",
    }
    result = subprocess.run(
        ["bash", str(DISPATCHER), "child.yml", "1"],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 1
    assert "DISPATCH_CANCEL_ON_TIMEOUT must be true or false" in result.stderr


def test_timeout_minutes_must_be_a_positive_integer(tmp_path: Path) -> None:
    env = {**os.environ, "GH_TOKEN": "test-token", "REPO": "example/repo"}
    result = subprocess.run(
        ["bash", str(DISPATCHER), "child.yml", "0"],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 1
    assert "timeout_minutes must be a positive integer" in result.stderr


def test_dispatch_capacity_slots_must_be_a_positive_integer(tmp_path: Path) -> None:
    env = {
        **os.environ,
        "GH_TOKEN": "test-token",
        "REPO": "example/repo",
        "DISPATCH_CAPACITY_SLOTS": "0",
    }
    result = subprocess.run(
        ["bash", str(DISPATCHER), "child.yml", "1"],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 1
    assert "DISPATCH_CAPACITY_SLOTS must be a positive integer" in result.stderr


def test_dispatcher_has_opt_in_managed_estate_drain() -> None:
    script = DISPATCHER.read_text()

    assert 'DISPATCH_ESTATE_DRAIN="${DISPATCH_ESTATE_DRAIN:-false}"' in script
    assert 'DISPATCH_ESTATE_DRAIN_INTERVAL="${DISPATCH_ESTATE_DRAIN_INTERVAL:-900}"' in script
    assert "fsa-estate-drain-${marker_id}.stamp" in script
    assert '"${script_dir}/managed-estate-queue-drain.py"' in script
    assert "--platform github" in script
    assert "--protect-run-id" in script


def test_full_chain_supplies_required_inputs_and_fails_closed() -> None:
    workflow = FULL_CHAIN.read_text()

    assert 'DISPATCH_CANCEL_RETRIES: "1"' in workflow
    assert "DISPATCH_CANCEL_EXIT_CODE" not in workflow
    assert "Stage cancelled by queue-manager — continuing." not in workflow
    assert "sync-fsa-forks.yml 30" in workflow
    assert "sync-uaa-vendor.yml 30" in workflow
    assert "sync-shell-tools.yml 30" in workflow
    assert "sync-template.yml 45 '{\"mode\":\"propagate\"}'" in workflow
    assert workflow.count('\"block_on_mismatch\":\"true\"') == 3
    assert '\"block_on_mismatch\":\"false\"' not in workflow
    assert 'post-flush-prep.yml 60 \'{\"repo_filter\":\"\",\"block_on_failure\":\"true\"}\'' in workflow


def test_full_chain_uses_dependency_linked_jobs_with_safe_dispatch_budgets() -> None:
    workflow_text = FULL_CHAIN.read_text()
    jobs = yaml.safe_load(workflow_text)["jobs"]
    phases = [
        "source_phase", "content_phase", "readme_finish_phase",
        "enrichment_phase", "source_mirror_phase", "mirror_phase",
        "gitlab_mirror_phase", "reconcile_phase", "post_reconcile_phase",
        "publish_phase", "deploy_phase",
    ]

    assert "sync-from-gitlab.yml" not in workflow_text
    assert 'git-platform-sync.yml 70 \'{"direction":"pull"}\'' in workflow_text
    previous = None
    for phase in phases:
        job = jobs[phase]
        if previous:
            needs = job.get("needs", [])
            needs = [needs] if isinstance(needs, str) else needs
            assert previous in needs
        dispatch_budget = 0
        for step in job["steps"]:
            run = step.get("run", "")
            if "flush-stage-dispatch.sh" in run:
                dispatch_budget += int(run.split("flush-stage-dispatch.sh", 1)[1].split()[1])
        assert dispatch_budget < job["timeout-minutes"]
        previous = phase

    assert "deploy_phase" in jobs["finalize"]["needs"]


def test_full_chain_builds_all_book_inputs_before_deploying() -> None:
    workflow = FULL_CHAIN.read_text()
    deploy = workflow.index('name: "Stage 24: Deploy book"')
    for stage in (
        'name: "Stage 19: Generate book pages"',
        'name: "Stage 20: Update book index"',
        'name: "Stage 21: Sync penguins-eggs docs to book"',
        'name: "Stage 22: Generate OSP dependency graph"',
        'name: "Stage 23: Generate SBOM"',
    ):
        assert workflow.index(stage) < deploy


def test_full_chain_progress_matches_dispatch_count() -> None:
    workflow = FULL_CHAIN.read_text()
    dispatch_count = workflow.count("bash scripts/flush-stage-dispatch.sh")

    assert dispatch_count == 46
    assert "number_of_steps: 38" not in workflow
    assert workflow.count(f"number_of_steps: {dispatch_count}") == 26
    assert 'subtitle: "All 46 stages complete"' in workflow
    assert "current_step: 46" in workflow
