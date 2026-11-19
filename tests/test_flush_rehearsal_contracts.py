"""Regression tests for execution-faithful, fail-closed flush rehearsal."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess

import yaml


ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "config/flush-stage-contracts.yml"
WRAPPER = ROOT / "scripts/flush-stage-dispatch.sh"
VALIDATOR = ROOT / "scripts/validate-flush-stage-contracts.py"


def run_wrapper(workflow: str, mode: str, inputs: str = "{}") -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(WRAPPER), workflow, "5", inputs],
        cwd=ROOT,
        env={
            **os.environ,
            "FLUSH_EXECUTION_MODE": mode,
            "REPO": "Interested-Deving-1896/fork-sync-all",
            "DISPATCH_VALIDATE_ONLY": "true",
        },
        capture_output=True,
        text=True,
        check=False,
    )


def test_contract_validator_covers_both_orchestrators() -> None:
    result = subprocess.run(
        ["python3", str(VALIDATOR)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert "Validated 43 flush stage contracts" in result.stderr
    contracts = yaml.safe_load(CONTRACT.read_text())["contracts"]
    assert not {
        workflow
        for workflow, contract in contracts.items()
        if contract["rehearsal"]["safety"] == "unsupported"
    }


def test_rehearsal_forces_safe_inputs_over_live_call_site() -> None:
    result = run_wrapper(
        "cleanup-branches.yml",
        "rehearsal",
        '{"dry_run":false,"force_delete":true}',
    )
    assert result.returncode == 0, result.stderr
    body = json.loads(result.stdout)
    assert body["inputs"]["dry_run"] is True
    assert body["inputs"]["force_delete"] is False


def test_live_cleanup_never_inherits_child_dry_run_default() -> None:
    result = run_wrapper("cleanup-branches.yml", "live")
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["inputs"]["dry_run"] is False


def test_live_stage_nine_routes_to_the_effective_repository() -> None:
    result = run_wrapper("mirror-chain-dispatch.yml", "live")
    assert result.returncode == 0, result.stderr
    body = json.loads(result.stdout)
    assert "workflow=mirror-chain-dispatch.yml repository=Interested-Deving-1896/fork-sync-all" in result.stderr
    assert body["inputs"] == {
        "chain_position": "mirror",
        "source_owner": "OpenOS-Project-OSP",
        "dest_backends": "github:OpenOS-Project-Ecosystem-OOC",
        "operations": "mirror-github",
        "repo_filter": "",
        "force": False,
        "dry_run": False,
    }


def test_rehearsal_makes_stage_nine_and_bdfs_safe() -> None:
    mirror = run_wrapper("mirror-chain-dispatch.yml", "rehearsal")
    bdfs = run_wrapper("bdfs-package.yml", "rehearsal")
    assert mirror.returncode == 0, mirror.stderr
    assert json.loads(mirror.stdout)["inputs"]["dry_run"] is True
    assert bdfs.returncode == 0, bdfs.stderr
    assert json.loads(bdfs.stdout)["inputs"] == {
        "dry_run": True,
        "upload_release": False,
    }


def test_rehearsal_executes_safe_shell_smoke_tests() -> None:
    result = run_wrapper("integrate-shell-tools.yml", "rehearsal")
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["inputs"] == {}


def test_post_flush_and_config_validation_are_safe_in_rehearsal() -> None:
    post_flush = run_wrapper("post-flush-prep.yml", "rehearsal")
    validate = run_wrapper("validate-config.yml", "rehearsal")
    assert post_flush.returncode == 0, post_flush.stderr
    assert json.loads(post_flush.stdout)["inputs"] == {
        "repo_filter": "",
        "block_on_failure": True,
        "dry_run": True,
    }
    assert validate.returncode == 0, validate.stderr
    assert json.loads(validate.stdout)["inputs"] == {"dry_run": True}


def test_dispatcher_reserves_contract_peak_runner_slots() -> None:
    contracts = yaml.safe_load(CONTRACT.read_text())["contracts"]
    dispatcher = WRAPPER.read_text()
    waiter = (ROOT / "scripts/dispatch-and-wait.sh").read_text()
    assert contracts["validate-config.yml"]["capacity_slots"] == 12
    assert 'DISPATCH_CAPACITY_SLOTS="$capacity_slots"' in dispatcher
    assert '--slots "$DISPATCH_CAPACITY_SLOTS"' in waiter


def test_full_chain_has_distinct_plan_rehearsal_and_live_paths() -> None:
    workflow = (ROOT / ".github/workflows/full-chain-flush.yml").read_text()
    parsed = yaml.safe_load(workflow)
    inputs = parsed[True]["workflow_dispatch"]["inputs"]
    assert inputs["execution_mode"]["options"] == ["live", "rehearsal", "plan"]
    assert workflow.count("bash scripts/flush-stage-dispatch.sh") == 46
    assert "Cheap plan (no execution)" in workflow
    assert "FLUSH_EXECUTION_MODE:" in workflow
    assert "DISPATCH_ESTATE_DRAIN: ${{ inputs.execution_mode == 'rehearsal' && 'false' || 'true' }}" in workflow
    assert "QUOTA_WRITE_VAR: ${{ inputs.execution_mode == 'rehearsal' && 'false' || 'true' }}" in workflow
    assert "inputs.managed_by_lifecycle != true && inputs.execution_mode != 'rehearsal'" in workflow
    assert workflow.count("inputs.execution_mode != 'rehearsal' && secrets.ACTIVITYSMITH_API_KEY != ''") == 12
    assert "inputs.execution_mode == 'rehearsal' || vars.BDFS_PACKAGE_ENABLED == 'true'" in workflow
    assert "inputs.execution_mode != 'rehearsal' && vars.BDFS_PACKAGE_ENABLED != 'true'" in workflow


def test_lifecycle_propagates_rehearsal_without_taking_live_lease() -> None:
    workflow = (ROOT / ".github/workflows/flush-lifecycle.yml").read_text()
    assert "steps.trigger_check.outputs.execution_mode == 'live'" in workflow
    assert "needs.lifecycle.outputs.execution_mode == 'live'" in workflow
    assert "FLUSH_EXECUTION_MODE: ${{ needs.lifecycle.outputs.execution_mode }}" in workflow
    assert "execution_mode=rehearsal" in workflow
