"""Regression tests for configurable merge/rebase PR branch updates."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "rebase-prs.sh"
WORKFLOW = ROOT / ".github" / "workflows" / "rebase-prs.yml"


def test_branch_update_script_has_valid_bash_syntax() -> None:
    result = subprocess.run(
        ["bash", "-n", str(SCRIPT)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr


def test_invalid_update_method_fails_before_network_access() -> None:
    env = os.environ.copy()
    env.update(
        {
            "GH_TOKEN": "test-token",
            "REPO": "owner/repo",
            "UPDATE_METHOD": "fast-forward",
        }
    )
    result = subprocess.run(
        ["bash", str(SCRIPT)],
        env=env,
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 2
    assert "UPDATE_METHOD must be 'merge' or 'rebase'" in result.stderr


def test_rebase_uses_supported_github_cli_mode_and_merge_uses_head_guard() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    assert 'gh pr update-branch "$number" --rebase --repo "$REPO"' in script
    assert '"expected_head_sha": os.environ["EXPECTED_HEAD_SHA"]' in script
    assert '"update_method": os.environ["UPDATE_METHOD"]' not in script


def test_manual_workflow_exposes_merge_and_rebase_choices() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    assert "update_method:" in workflow
    assert "type: choice" in workflow
    assert "default: merge" in workflow
    assert "          - merge\n          - rebase" in workflow
    assert "vars.BRANCH_UPDATE_METHOD" in workflow


def test_branch_refresh_workflow_uses_control_plane_mode_gate() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    assert "if fsa_should_run_control_plane; then" in workflow
    assert "if fsa_is_managed; then" not in workflow
    assert 'echo "managed=false" >> "$GITHUB_OUTPUT"' in workflow
    assert 'echo "managed=true" >> "$GITHUB_OUTPUT"' in workflow

