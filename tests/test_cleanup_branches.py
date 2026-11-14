"""Safety regression tests for cleanup-branches.sh."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "cleanup-branches.sh"
WORKFLOW = ROOT / ".github" / "workflows" / "cleanup-branches.yml"


def test_cleanup_script_has_valid_bash_syntax() -> None:
    result = subprocess.run(
        ["bash", "-n", str(SCRIPT)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr


def test_cleanup_defaults_to_dry_run() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    assert 'DRY_RUN="${DRY_RUN:-true}"' in script


def test_invalid_safety_flags_fail_before_network_access() -> None:
    for variable, value in (("DRY_RUN", "yes"), ("FORCE_DELETE", "1")):
        env = os.environ.copy()
        env.update({"GH_TOKEN": "test-token", "ORGS": "example-org", variable: value})
        result = subprocess.run(
            ["bash", str(SCRIPT)],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        assert result.returncode == 2
        assert f"{variable} must be true or false" in result.stderr


def test_incomplete_branch_inventory_skips_repo_and_default_branch_is_not_guessed() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    assert "Branch inventory request failed" in script
    assert "Invalid branch inventory" in script
    assert "No verified default branch" in script
    assert 'type == "array" and all(.[]; type == "object" and (.name | type == "string" and length > 0))' in script
    assert "default_branch=$(jq -er" in script
    assert "default_branch=$(jq -r '.default_branch // \"main\"'" not in script


def test_compare_and_open_pr_errors_fail_closed() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    assert "Invalid compare response" in script
    assert 'ahead_by" -eq 0 && ( "$status" == "behind" || "$status" == "identical" )' in script
    assert "Could not verify open PR state" in script
    assert "Invalid open PR response" in script


def test_non_manual_cleanup_triggers_cannot_enable_live_deletion() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    assert "github.event_name == 'workflow_dispatch' && inputs.dry_run == false" in workflow


def test_repository_inventory_errors_skip_the_account_or_org() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    assert "User repository inventory failed" in script
    assert "Invalid user repository inventory" in script
    assert "Repo list failed for" in script
    assert "Invalid repository inventory for" in script
    assert "skipping entire org" in script
    # User repository enumeration deliberately uses paginated REST, not a
    # truncated first-page GraphQL snapshot for destructive cleanup decisions.
    user_section = script.split('if [[ "$account_type" == "User" ]]', 1)[1].split('else\n    # Org account', 1)[0]
    assert "repositories(first: 100" not in user_section


def test_org_cleanup_inventory_does_not_use_truncated_graphql_shortcut() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    assert 'mapfile -t _gql_repos < <(list_org_repos_graphql "$org")' not in script
    assert 'orgs/${org}/repos?per_page=100&page=${page}&type=all' in script
    assert 'Repo list failed for ${org} — skipping entire org' in script
    assert 'Invalid repository inventory for ${org} — skipping entire org' in script
