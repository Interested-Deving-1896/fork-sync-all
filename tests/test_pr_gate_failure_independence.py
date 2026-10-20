"""Regression checks for PR Gate degraded-path failure independence.

These checks intentionally inspect the workflow contract rather than exercising
GitHub's live API or exhausting any rate limit.
"""

from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "pr-gate.yml"


def _steps_by_name(workflow: str) -> dict[str, str]:
    """Extract simple step blocks by their exact name from this workflow YAML."""
    lines = workflow.splitlines()
    starts = []
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("- name: "):
            starts.append((index, stripped[len("- name: "):].strip().strip("\\"'")))
    result = {}
    for position, (start, name) in enumerate(starts):
        end = starts[position + 1][0] if position + 1 < len(starts) else len(lines)
        result[name] = "\n".join(lines[start:end])
    return result


def test_degraded_diagnostics_are_best_effort():
    workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
    steps = _steps_by_name(workflow)
    diagnostics = steps["Post degraded-system comment"]

    assert "continue-on-error: true" in diagnostics
    assert "if: steps.health.outputs.healthy == 'false'" in diagnostics


def test_degraded_health_still_has_explicit_failing_gate_step():
    workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
    steps = _steps_by_name(workflow)
    failure = steps["Fail gate on degraded system"]

    assert "if: steps.health.outputs.healthy == 'false'" in failure
    assert "exit 1" in failure


def test_healthy_path_is_separate_from_degraded_path():
    workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
    steps = _steps_by_name(workflow)
    passed = steps["Gate passed"]

    assert "if: steps.health.outputs.healthy == 'true'" in passed
