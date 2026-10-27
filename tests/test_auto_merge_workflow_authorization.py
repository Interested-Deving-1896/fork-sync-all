"""Regression tests for auto-merge workflow authorization and branch safety."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "auto-merge-prs.yml"


def test_automatic_auto_merge_triggers_are_report_only() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    assert "github.event_name != 'workflow_dispatch' || !inputs.enable_live_merge || inputs.dry_run" in workflow


def test_branch_deletion_is_not_implicitly_authorized() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    assert 'DELETE_BRANCH: "false"' in workflow
    assert 'DELETE_BRANCH: "true"' not in workflow


def test_live_merge_requires_separate_manual_opt_in() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    assert "enable_live_merge:" in workflow
    assert "default: false" in workflow
    assert "dry_run:" in workflow


def test_enable_live_merge_input_defaults_to_false_in_its_own_block() -> None:
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    start = lines.index("      enable_live_merge:")
    block = [lines[start]]
    for line in lines[start + 1 :]:
        if line and not line.startswith("        "):
            break
        block.append(line)

    input_block = "\n".join(block)
    assert "type: boolean" in input_block
    assert "default: false" in input_block


def test_dry_run_is_checked_before_live_merge_can_be_enabled() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    assert "github.event_name != 'workflow_dispatch' || !inputs.enable_live_merge || inputs.dry_run" in workflow
