"""Regression tests for registered-import target creation."""

import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
GH_API = ROOT / "scripts/includes/gh-api.sh"
SYNC_SCRIPT = ROOT / "scripts/sync-registered-imports.sh"


def run_helper(owner: str) -> subprocess.CompletedProcess[str]:
    script = f"""
set -uo pipefail
export GH_TOKEN=test-token
source {GH_API!s}
gh_get() {{ printf '%s' '{{"login":"alice"}}'; }}
gh_api() {{ printf '%s\\n' "$2"; printf '%s\\n' '{{"id":1}}'; }}
_GH_AUTH_LOGIN=''
gh_create_repo {owner} demo
"""
    return subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env=os.environ,
        capture_output=True,
        text=True,
        check=False,
    )


def test_authenticated_user_repo_uses_user_endpoint() -> None:
    result = run_helper("alice")

    assert result.returncode == 0, result.stderr
    assert "https://api.github.com/user/repos" in result.stdout
    assert "/orgs/alice/repos" not in result.stdout


def test_organization_repo_uses_org_endpoint() -> None:
    result = run_helper("example-org")

    assert result.returncode == 0, result.stderr
    assert "https://api.github.com/orgs/example-org/repos" in result.stdout


def test_source_is_cloned_before_missing_target_is_created() -> None:
    script = SYNC_SCRIPT.read_text()
    function_body = script.split("sync_entry() {", 1)[1].split("\n}", 1)[0]

    assert function_body.index("git clone --mirror") < function_body.index(
        'ensure_gh_repo "$target_name"'
    )
    assert "stale registry entry" in function_body


def test_workflow_passes_dispatch_filters_to_sync_script() -> None:
    workflow = (ROOT / ".github/workflows/sync-registered-imports.yml").read_text()

    assert "REPO_FILTER: ${{ inputs.repo_filter || '' }}" in workflow
    assert "DRY_RUN: ${{ inputs.dry_run || false }}" in workflow
    assert "SOURCE_FILTER: ${{ inputs.source_filter || '' }}" in workflow
    assert "FORCE_SYNC: ${{ inputs.force_sync || false }}" in workflow


def test_registry_does_not_self_sync_deleted_taubyte_repo() -> None:
    registry = (ROOT / "registered-imports.json").read_text()

    assert '"source_url": "https://github.com/Interested-Deving-1896/taubyte"' not in registry
