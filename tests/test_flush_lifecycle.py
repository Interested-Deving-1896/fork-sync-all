"""Regression checks for dry-run routing through the flush lifecycle."""

import json
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def test_lifecycle_dispatches_typed_boolean_inputs() -> None:
    workflow = (ROOT / ".github/workflows/flush-lifecycle.yml").read_text()

    assert "'dry_run':b('DRY_RUN')" in workflow
    assert "'continue_pipeline':False" in workflow
    assert "'managed_by_lifecycle':True" in workflow
    assert "'skip_post_flush':b('SKIP_POST_FLUSH')" in workflow
    assert "'dry_run':os.environ['DRY_RUN']" not in workflow


def test_children_fail_safe_to_raw_dry_run_event_input() -> None:
    full_chain = (ROOT / ".github/workflows/full-chain-flush.yml").read_text()
    pre_flush = (ROOT / ".github/workflows/pre-flush-prep.yml").read_text()

    raw_dry_run = "github.event.inputs.dry_run == 'true'"
    assert f"inputs.dry_run == true || {raw_dry_run}" in full_chain
    assert f"inputs.dry_run != true && {raw_dry_run.replace('==', '!=')}" in full_chain
    assert f"DRY_RUN: ${{{{ inputs.dry_run == true || {raw_dry_run} }}}}" in pre_flush
    assert "github.event.inputs.continue_pipeline == 'true'" in pre_flush


def test_registered_import_loop_does_not_use_local_outside_function() -> None:
    script = (ROOT / "scripts/sync-registered-imports.sh").read_text()

    assert "\n  sync_rc=0\n" in script
    assert "\n  local sync_rc=0\n" not in script


def test_dispatcher_preserves_supplied_boolean_inputs() -> None:
    result = subprocess.run(
        [
            "bash",
            str(ROOT / "scripts/dispatch-and-wait.sh"),
            "child.yml",
            "1",
            '{"dry_run":true,"continue_pipeline":false}',
        ],
        env={**os.environ, "DISPATCH_VALIDATE_ONLY": "true"},
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {
        "ref": "main",
        "inputs": {"dry_run": True, "continue_pipeline": False},
    }


def test_dispatcher_rejects_malformed_inputs_instead_of_using_defaults() -> None:
    result = subprocess.run(
        [
            "bash",
            str(ROOT / "scripts/dispatch-and-wait.sh"),
            "child.yml",
            "1",
            '{"dry_run":true}}',
        ],
        env={**os.environ, "DISPATCH_VALIDATE_ONLY": "true"},
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 1
    assert "inputs_json must be a valid JSON object" in result.stderr
