"""Regression coverage for workflow-dispatch dry-run safety controls."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

NORMALIZED_DRY_RUN = (
    "DRY_RUN: ${{ inputs.dry_run == true || "
    "github.event.inputs.dry_run == 'true' }}"
)


def workflow(name: str) -> str:
    return (WORKFLOWS / name).read_text()


def test_mutating_workflows_propagate_normalized_dry_run_to_scripts() -> None:
    for name in (
        "sync-forks.yml",
        "update-readmes.yml",
        "mirror-to-osp.yml",
        "upstream-commits.yml",
        "upstream-prs.yml",
    ):
        text = workflow(name)
        assert NORMALIZED_DRY_RUN in text, name


def test_sync_forks_propagates_all_dispatch_safety_controls() -> None:
    text = workflow("sync-forks.yml")

    assert "REPO_FILTER: ${{ inputs.repo_filter || '' }}" in text
    assert "BRANCH_FILTER: ${{ inputs.branch_filter || '' }}" in text
    assert (
        "FORCE: ${{ inputs.force == true || "
        "github.event.inputs.force == 'true' }}"
    ) in text


def test_mirror_to_osp_propagates_filter_and_force_controls() -> None:
    text = workflow("mirror-to-osp.yml")

    assert "REPO_FILTER: ${{ inputs.repo_filter || '' }}" in text
    assert (
        "FORCE: ${{ inputs.force == true || "
        "github.event.inputs.force == 'true' }}"
    ) in text


def test_upstream_workflows_propagate_filters_and_mirror_orgs() -> None:
    default_orgs = "OpenOS-Project-OSP OpenOS-Project-Ecosystem-OOC"
    for name in ("upstream-commits.yml", "upstream-prs.yml"):
        text = workflow(name)
        assert "REPO_FILTER: ${{ inputs.repo_filter || '' }}" in text, name
        assert (
            "MIRROR_ORGS: ${{ inputs.mirror_orgs || '"
            f"{default_orgs}' }}"
        ) in text, name


def test_check_ci_blocks_resolver_for_boolean_or_string_dry_run() -> None:
    text = workflow("check-ci.yml")

    assert "inputs.dry_run != true" in text
    assert "github.event.inputs.dry_run != 'true'" in text
    assert re.search(r"(?<!event\.)inputs\.dry_run != 'true'", text) is None
