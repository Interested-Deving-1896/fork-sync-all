"""Regression tests for configurable merge/rebase PR branch updates."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "rebase-prs.sh"
WORKFLOW = ROOT / ".github" / "workflows" / "rebase-prs.yml"
PR_LIST_PARSER = ROOT / "scripts" / "parse-pr-branch-list.py"


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


def test_branch_refresh_workflow_is_scoped_and_scans_are_serialized() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    assert "cancel-in-progress: false" in workflow
    assert "inputs.repo" not in workflow
    assert "REPO: ${{ github.repository }}" in workflow
    assert "github.event.workflow_run.conclusion == 'success'" in workflow
    assert "github.event.repository.default_branch" in workflow


def _listing_pr(number: int = 1) -> dict[str, object]:
    return {
        "number": number,
        "state": "open",
        "draft": False,
        "title": f"PR {number}",
        "head": {
            "ref": f"feature-{number}",
            "sha": "a" * 40,
        },
        "base": {"ref": "main"},
    }


def test_pr_listing_parser_accepts_complete_valid_entries() -> None:
    result = subprocess.run(
        ["python3", str(PR_LIST_PARSER)],
        input=json.dumps([_listing_pr()]),
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    parsed = json.loads(result.stdout)
    assert parsed["number"] == 1
    assert parsed["head_sha"] == "a" * 40
    assert parsed["base_ref"] == "main"


def test_pr_listing_parser_rejects_malformed_or_duplicate_entries() -> None:
    malformed = _listing_pr()
    malformed["head"] = {"ref": "feature-1", "sha": "not-a-sha"}
    for payload in ({"unexpected": "object"}, [malformed], [_listing_pr(), _listing_pr()]):
        result = subprocess.run(
            ["python3", str(PR_LIST_PARSER)],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode != 0


def test_branch_refresh_aborts_incomplete_listing_and_rechecks_exact_head() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    listing = script.split("# ── Fetch and validate the complete PR snapshot", 1)[1]
    listing = listing.split("# ── Counters", 1)[0]
    assert "if ! batch=$(gh_get" in listing
    assert "refusing to process an incomplete snapshot" in listing
    assert "parse-pr-branch-list.py" in listing
    assert "duplicate PR" in listing
    assert "observed_head_sha" in script
    assert "snapshot changed since listing" in script


def test_control_plane_mode_gate_behavior_without_network_access() -> None:
    """Exercise the sourced shell predicate in all three repository modes."""
    helper = ROOT / "scripts" / "includes" / "fsa-mode.sh"
    command = (
        'source "$FSA_MODE_HELPER"; '
        'if fsa_should_run_control_plane; then exit 0; else exit 1; fi'
    )

    cases = [
        (
            "canonical control plane overrides managed marker",
            {
                "GITHUB_REPOSITORY": "Interested-Deving-1896/fork-sync-all",
                "FSA_CANONICAL_OWNER": "Interested-Deving-1896",
                "FSA_MANAGED": "true",
                "GH_TOKEN": "",
            },
            0,
        ),
        (
            "managed consumer skips local fallback",
            {
                "GITHUB_REPOSITORY": "example/consumer",
                "FSA_CANONICAL_OWNER": "Interested-Deving-1896",
                "FSA_MANAGED": "true",
                "GH_TOKEN": "",
            },
            1,
        ),
        (
            "autonomous repository runs local fallback",
            {
                "GITHUB_REPOSITORY": "example/autonomous",
                "FSA_CANONICAL_OWNER": "Interested-Deving-1896",
                "FSA_MANAGED": "false",
                "GH_TOKEN": "",
            },
            0,
        ),
    ]

    for description, overrides, expected_returncode in cases:
        env = os.environ.copy()
        env.update(overrides)
        env["FSA_MODE_HELPER"] = str(helper)
        result = subprocess.run(
            ["bash", "-c", command],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        assert result.returncode == expected_returncode, (
            f"{description}: expected exit {expected_returncode}, "
            f"got {result.returncode}; stderr={result.stderr!r}"
        )
