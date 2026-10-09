from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/agent-budget-governor.yml"
INCLUDE = ROOT / "scripts/includes/agent-budget.sh"


def load_workflow():
    data = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    triggers = data.get("on", data.get(True, {})) or {}
    return data, triggers


def test_governor_is_serialized_and_supports_external_observations():
    workflow, triggers = load_workflow()
    assert workflow["concurrency"] == {
        "group": "agent-compute-budget-governor",
        "cancel-in-progress": False,
    }
    assert "schedule" in triggers
    assert "workflow_dispatch" in triggers
    assert triggers["repository_dispatch"]["types"] == ["agent-budget-observation"]


def test_governor_defaults_to_shadow_mode():
    _, triggers = load_workflow()
    shadow = triggers["workflow_dispatch"]["inputs"]["shadow_mode"]
    assert shadow["type"] == "boolean"
    assert shadow["default"] is True


def test_enterprise_observer_uses_separate_read_only_secret():
    workflow, _ = load_workflow()
    step = next(
        item
        for item in workflow["jobs"]["govern"]["steps"]
        if item.get("id") == "govern"
    )
    assert step["env"]["ONA_API_KEY"] == "${{ secrets.ONA_BILLING_TOKEN }}"
    script = step["run"]
    assert "scripts/agent-budget-ona.py" in script
    assert "ONA_CREDIT_LIMIT" in script
    assert "StopAgentExecution" not in script


def test_state_is_stored_in_actions_variables_not_committed():
    text = WORKFLOW.read_text(encoding="utf-8")
    assert "AI_AGENT_BUDGET_STATE_" in text
    assert "/actions/variables" in text
    assert "git commit" not in text
    assert "git push" not in text


def test_unknown_or_stale_decision_is_enforced_only_outside_shadow_mode():
    text = WORKFLOW.read_text(encoding="utf-8")
    assert 'if [[ "$SHADOW" == "false" && "$baseline_allowed" != "true" ]]' in text
    assert "Agent work deferred by the compute-budget governor" in text


def test_execution_control_is_allowlisted_opt_in_and_uses_separate_secret():
    workflow, _ = load_workflow()
    step = next(
        item
        for item in workflow["jobs"]["govern"]["steps"]
        if item.get("name") == "Control registered Ona executions"
    )
    assert step["env"]["ONA_API_KEY"] == "${{ secrets.ONA_AGENT_CONTROL_TOKEN }}"
    assert "AI_AGENT_BUDGET_ONA_EXECUTIONS" in step["env"]["EXECUTION_IDS_JSON"]
    script = step["run"]
    assert 'AUTO_PAUSE" == "true"' in script
    assert 'AUTO_RESUME" == "true"' in script
    assert 'BASELINE_REASON" == "below-pause-threshold"' in script
    assert 'SHADOW" != "false"' in script
    assert 'BASELINE_ALLOWED" == "true"' in script
    assert 'PREVIOUS_PAUSED" != "true"' not in script
    assert 'REQUEST_ACTION" != "observe"' in script
    assert "--apply" in script
    assert "StopAgentExecution" not in script


def test_cooperative_helper_uses_canonical_github_api_include():
    text = INCLUDE.read_text(encoding="utf-8")
    assert 'source "${_agent_budget_include_dir}/gh-api.sh"' in text
    assert "gh_get \"https://api.github.com/repos/${repository}/actions/variables/${variable}\"" in text
    assert "gh api " not in text
