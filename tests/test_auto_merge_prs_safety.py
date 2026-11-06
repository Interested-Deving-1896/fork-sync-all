"""Regression tests for auto-merge fail-safe defaults."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "auto-merge-prs.sh"
WORKFLOW = ROOT / ".github" / "workflows" / "auto-merge-prs.yml"


def test_auto_merge_helper_has_valid_bash_syntax() -> None:
    result = subprocess.run(
        ["bash", "-n", str(SCRIPT)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr


def test_auto_merge_helper_defaults_to_dry_run_and_keeps_branches() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    assert 'DRY_RUN="${DRY_RUN:-true}"' in script
    assert 'DELETE_BRANCH="${DELETE_BRANCH:-false}"' in script
    assert 'DRY_RUN must be true or false' in script
    assert 'DELETE_BRANCH must be true or false' in script


def test_invalid_safety_flags_fail_before_token_or_network_use() -> None:
    for variable in ("DRY_RUN", "DELETE_BRANCH"):
        env = os.environ.copy()
        env.pop("GH_TOKEN", None)
        env.pop("GITHUB_TOKEN", None)
        env[variable] = "maybe"
        result = subprocess.run(
            ["bash", str(SCRIPT)],
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        assert result.returncode == 2
        assert f"{variable} must be true or false" in result.stderr
        assert "GH_TOKEN is required" not in result.stderr


def test_workflow_only_allows_live_mode_for_manual_explicit_opt_in() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    assert "default: true" in workflow
    assert "github.event_name == 'workflow_dispatch' && inputs.dry_run == false" in workflow
    assert "DRY_RUN: ${{ github.event_name == 'workflow_dispatch' && inputs.dry_run == false && 'false' || 'true' }}" in workflow
    assert 'DELETE_BRANCH: "false"' in workflow
