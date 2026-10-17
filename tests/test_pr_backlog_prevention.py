"""Regression checks for automated PR fan-out prevention."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_workflow_proposals_are_dry_run_first_and_bounded() -> None:
    workflow = (ROOT / ".github/workflows/upstream-workflow-proposal.yml").read_text()
    script = (ROOT / "scripts/upstream-workflow-proposal.sh").read_text()

    assert "default: true" in workflow
    assert "github.event_name == 'schedule' || inputs.dry_run" in workflow
    assert "MAX_PROPOSALS" in workflow
    assert "reserved_workflow_names" in script
    assert "proposed >= MAX_PROPOSALS" in script
    assert "draft: true" in script


def test_vouch_sync_uses_registry_and_one_stable_pr() -> None:
    workflow = (ROOT / ".github/workflows/vouch-sync-codeowners.yml").read_text()

    assert "bash scripts/vouch-seed.sh" not in workflow
    assert "vouch/sync-codeowners\"" in workflow
    assert "vouch/sync-codeowners-$(date" not in workflow
    assert "Generated VOUCHED.td dropped the Tier 1 maintainer" in workflow
    assert "gh pr list --state open --head" in workflow
    assert "Co-authored-by: Ona" not in workflow
