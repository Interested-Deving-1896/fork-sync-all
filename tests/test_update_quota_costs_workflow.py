import re
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "update-quota-costs.yml"


def load_workflow():
    data = yaml.safe_load(WORKFLOW.read_text())
    triggers = data.get("on", data.get(True, {})) or {}
    return data, triggers


def compute_script(workflow):
    step = next(
        step
        for step in workflow["jobs"]["update"]["steps"]
        if step.get("id") == "compute"
    )
    match = re.fullmatch(
        r"python3 - <<'PYEOF'\n(.*)\nPYEOF\n?",
        step["run"],
        re.DOTALL,
    )
    assert match
    return match.group(1)


def test_cost_scan_is_weekly_or_manual_only():
    _, triggers = load_workflow()

    assert "schedule" in triggers
    assert "workflow_dispatch" in triggers
    assert "workflow_run" not in triggers


def test_cost_scan_uses_bounded_workflow_and_run_log_endpoints():
    workflow, _ = load_workflow()
    script = compute_script(workflow)

    assert "/actions/workflows?per_page=100&page=" in script
    assert "/actions/workflows/{workflow_id}/runs" in script
    assert "/actions/runs/{run_id}/logs" in script
    assert "/actions/runs?per_page=100&page=" not in script
    assert "/actions/jobs/{job_id}/logs" not in script


def test_cost_scan_parses_fallback_markers_per_run_and_compiles():
    workflow, _ = load_workflow()
    script = compute_script(workflow)

    assert "structured_matches = list(MARKER.finditer(log_text))" in script
    assert "if not structured_matches:" in script
    compile(script, str(WORKFLOW) + ":compute", "exec")


def test_cost_scan_requires_sufficient_headroom():
    workflow, _ = load_workflow()
    quota_step = next(
        step
        for step in workflow["jobs"]["update"]["steps"]
        if step.get("id") == "quota"
    )

    assert int(quota_step["env"]["MIN_QUOTA"]) >= 500
