"""Regression checks for dry-run routing through the flush lifecycle."""

import json
import os
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def test_lifecycle_dispatches_typed_boolean_inputs() -> None:
    workflow = (ROOT / ".github/workflows/flush-lifecycle.yml").read_text()

    assert "'dry_run':b('DRY_RUN')" in workflow
    assert "'continue_pipeline':False" in workflow
    assert "'managed_by_lifecycle':True" in workflow
    assert "'skip_post_flush':b('SKIP_POST_FLUSH')" in workflow
    assert "'dry_run':os.environ['DRY_RUN']" not in workflow


def test_lifecycle_splits_child_waits_into_bounded_jobs() -> None:
    workflow = (ROOT / ".github/workflows/flush-lifecycle.yml").read_text()

    assert "timeout-minutes: 355" in workflow
    assert "timeout-minutes: 350" in workflow
    assert "name: Release Flush Lease" in workflow
    assert "full-chain-flush cancelled — retrying" not in workflow
    assert "pre-flush-prep cancelled 3 times" not in workflow
    assert "Renew FLUSH_ACTIVE lease" in workflow


def test_watchdog_is_router_driven_and_owner_aware() -> None:
    workflow = (ROOT / ".github/workflows/flush-active-watchdog.yml").read_text()

    assert "workflow_run:" not in workflow
    assert "protected_workflow:" in workflow
    assert "protected_run_id:" in workflow
    assert "protected_run_attempt:" in workflow
    assert 'PIPELINE_LEASE_OWNER="${TRIGGERING_WORKFLOW}:${TRIGGERING_RUN_ID}:${TRIGGERING_RUN_ATTEMPT}"' in workflow
    assert 'pipeline_guard_end "watchdog"' in workflow


def test_pre_flush_protects_control_plane_and_checks_pr_details() -> None:
    script = (ROOT / "scripts/pre-flush-prep.sh").read_text()

    assert '[[ "$run_id" == "$this_run_id"' in script
    assert 'entry.get(\'tier\') == 1' in script
    assert 'protected_names=(["Flush Lifecycle Manager"]=1)' in script
    assert 'pulls/${pr_num}' in script
    assert "if not runs: print('no-checks')" in script


def test_canonical_repo_runs_control_plane_but_managed_consumer_does_not() -> None:
    mode = ROOT / "scripts/includes/fsa-mode.sh"
    command = f'''source "{mode}"
GITHUB_REPOSITORY=Interested-Deving-1896/fork-sync-all
FSA_MANAGED=true
fsa_should_run_control_plane || exit 10
GITHUB_REPOSITORY=OpenOS-Project-OSP/consumer
fsa_should_run_control_plane && exit 11
exit 0
'''
    result = subprocess.run(
        ["bash", "-c", command],
        env={**os.environ, "GH_TOKEN": "", "FSA_MANAGED": "true"},
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr


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


def sentinel_tier(workflow_name: str, config_path: Path) -> subprocess.CompletedProcess[str]:
    sentinel = (ROOT / "scripts/flush-sentinel.sh").read_text()
    match = re.search(
        r"get_tier\(\) \{.*?<< 'PYEOF'\n(.*?)\nPYEOF",
        sentinel,
        re.DOTALL,
    )
    assert match is not None
    return subprocess.run(
        ["python3", "-", str(config_path), workflow_name],
        input=match.group(1),
        capture_output=True,
        text=True,
        check=False,
    )


def test_flush_sentinel_reads_flat_priority_registry() -> None:
    config = ROOT / "config/workflow-priority-tiers.yml"

    assert sentinel_tier("Flush Lifecycle Manager", config).stdout.strip() == "1"
    assert sentinel_tier("Full Chain Flush", config).stdout.strip() == "2"
    assert sentinel_tier("Unknown Workflow", config).stdout.strip() == "3"


def test_flush_sentinel_fails_closed_on_invalid_priority_registry(tmp_path: Path) -> None:
    malformed = tmp_path / "workflow-priority-tiers.yml"
    malformed.write_text("tiers: [not: valid: yaml")
    result = sentinel_tier("Flush Lifecycle Manager", malformed)

    assert result.returncode == 0
    assert result.stdout.strip() == "1"
    assert "priority registry error" in result.stderr


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
