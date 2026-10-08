"""Regression coverage for the shell-tools production workflows."""

import os
from pathlib import Path
import subprocess

import yaml


ROOT = Path(__file__).resolve().parents[1]
INTEGRATE_WORKFLOW = ROOT / ".github/workflows/integrate-shell-tools.yml"
CHECK_WORKFLOW = ROOT / ".github/workflows/check-shell-tools-ci.yml"


def workflow_step_run(workflow: Path, job: str, step_name: str) -> str:
    config = yaml.safe_load(workflow.read_text())
    steps = config["jobs"][job]["steps"]
    return next(step["run"] for step in steps if step.get("name") == step_name)


def test_integrate_smoke_loop_preserves_counters_and_exit_status(tmp_path: Path) -> None:
    run = workflow_step_run(
        INTEGRATE_WORKFLOW, "smoke-tests", "Run smoke tests from registry"
    )

    (tmp_path / "config").mkdir()
    (tmp_path / "scripts/includes").mkdir(parents=True)
    (tmp_path / "config/shell-tools-registry.yml").write_text(
        """tools:
  - repo: passing-tool
    smoke_test: "printf 'pass output\\n'; true"
  - repo: failing-tool
    smoke_test: "bash -c 'printf fail-output; exit 7'"
  - repo: skipped-tool
    smoke_test: ""
"""
    )
    (tmp_path / "scripts/includes/quota-instrument.sh").write_text(
        "qi_begin() { :; }\nqi_end() { :; }\n"
    )
    (tmp_path / "scripts/includes/shell-tools.sh").write_text("")
    output_file = tmp_path / "github-output"

    result = subprocess.run(
        ["bash", "-e", "-o", "pipefail", "-c", run],
        cwd=tmp_path,
        env={
            **os.environ,
            "TOOL_FILTER": "",
            "DRY_RUN": "false",
            "FAIL_ON_ERROR": "false",
            "REPO_ROOT": str(tmp_path),
            "GITHUB_OUTPUT": str(output_file),
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "FAIL (exit 7)" in result.stdout
    assert "Results: passed=1 failed=1 skipped=1" in result.stdout
    assert output_file.read_text().splitlines() == [
        "passed=1",
        "failed=1",
        "skipped=1",
    ]


def test_integrate_uses_valid_heredoc_and_no_pipeline_subshell() -> None:
    run = workflow_step_run(
        INTEGRATE_WORKFLOW, "smoke-tests", "Run smoke tests from registry"
    )

    assert "PYEOF | while" not in run
    assert "done < \"$registry_rows\"" in run
    assert "read -r -d '' repo" in run
    assert "if eval \"$smoke_cmd\" > \"$smoke_log\" 2>&1; then" in run


def test_quota_instrumentation_stays_within_each_instrumented_step() -> None:
    integrate_run = workflow_step_run(
        INTEGRATE_WORKFLOW, "smoke-tests", "Run smoke tests from registry"
    )
    integrate_summary = workflow_step_run(
        INTEGRATE_WORKFLOW, "smoke-tests", "Write step summary"
    )
    check_run = workflow_step_run(
        CHECK_WORKFLOW, "check", "Fetch CI status via GraphQL"
    )
    check_summary = workflow_step_run(CHECK_WORKFLOW, "check", "Write step summary")

    for run in (integrate_run, check_run):
        assert "source scripts/includes/quota-instrument.sh" in run
        assert "qi_begin" in run
        assert "qi_end" in run
        assert "trap" in run

    assert "qi_end" not in integrate_summary
    assert "qi_end" not in check_summary
