from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"


def load_workflow(name):
    data = yaml.safe_load((WORKFLOWS / name).read_text())
    triggers = data.get("on", data.get(True, {})) or {}
    return data, triggers


def test_router_polls_instead_of_using_workflow_run_fan_in():
    workflow, triggers = load_workflow("workflow-completion-router.yml")
    assert "workflow_run" not in triggers
    assert "schedule" in triggers
    assert workflow["concurrency"]["cancel-in-progress"] is False
    route_script = workflow["jobs"]["route"]["steps"][-1]["run"]
    assert "gh api --paginate" in route_script
    assert "created_since" in route_script
    loop_end = route_script.index("done\n", route_script.index('for run in "${pending[@]}"'))
    assert route_script.index('write_cursor "$next_cursor"') < loop_end
    assert 'if [[ "$source_had_dispatch" == "true" ]]' in route_script
    assert 'if [[ "$persisted_cursor" != "$next_cursor" ]]' in route_script


def test_previous_fan_in_consumers_are_dispatch_only_or_scheduled():
    consumers = [
        "bugzilla-failure-report.yml",
        "create-readmes.yml",
        "gl-storage-scan.yml",
        "inject-badges.yml",
        "lts-readmes.yml",
        "mirror-orgs-watchdog.yml",
        "pipeline-telemetry.yml",
        "reconcile-identity-assets.yml",
        "resolve-ci.yml",
        "runner-status.yml",
        "translate-readmes.yml",
        "validate-readme-render.yml",
        "verify-mirror-integrity.yml",
    ]
    for name in consumers:
        _, triggers = load_workflow(name)
        assert "workflow_run" not in triggers, name


def test_flush_watchdog_dispatch_contract_matches_router():
    watchdog, triggers = load_workflow("flush-active-watchdog.yml")
    inputs = triggers["workflow_dispatch"]["inputs"]
    expected = {
        "protected_workflow",
        "protected_run_id",
        "protected_conclusion",
    }
    assert set(inputs) == expected

    router, _ = load_workflow("workflow-completion-router.yml")
    route_script = router["jobs"]["route"]["steps"][-1]["run"]
    for field in expected:
        assert f"-f {field}=" in route_script
