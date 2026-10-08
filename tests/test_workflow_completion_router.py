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
    assert "run_attempt: (.run_attempt // 1)" in route_script


def test_router_checkpoints_each_target_for_partial_failure_recovery():
    workflow, _ = load_workflow("workflow-completion-router.yml")
    route_script = workflow["jobs"]["route"]["steps"][-1]["run"]

    dispatch_start = route_script.index("dispatch() {")
    dispatch_end = route_script.index("\n}\n\nrouting_state=", dispatch_start)
    dispatch_function = route_script[dispatch_start:dispatch_end]
    assert "target_key=" in dispatch_function
    assert ".inflight.targets" in dispatch_function
    assert "Already dispatched" in dispatch_function
    assert 'write_cursor "$routing_state"' in dispatch_function
    assert dispatch_function.index('gh workflow run "$workflow"') < dispatch_function.index(
        'write_cursor "$routing_state"'
    )


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
        "protected_run_attempt",
        "protected_conclusion",
    }
    assert set(inputs) == expected

    router, _ = load_workflow("workflow-completion-router.yml")
    route_script = router["jobs"]["route"]["steps"][-1]["run"]
    for field in expected:
        assert f"-f {field}=" in route_script


def test_protected_lease_writers_share_concurrency_group():
    protected = [
        "flush-lifecycle.yml",
        "critical-deploy.yml",
        "critical-deploy-all.yml",
        "critical-deploy-github-osp.yml",
        "critical-deploy-github-ooc.yml",
        "critical-deploy-gitlab.yml",
        "flush-active-watchdog.yml",
    ]
    for name in protected:
        workflow, _ = load_workflow(name)
        assert workflow["concurrency"]["group"] == "protected-pipeline-lease", name
        assert workflow["concurrency"]["cancel-in-progress"] is False, name

    full_chain, _ = load_workflow("full-chain-flush.yml")
    group = full_chain["concurrency"]["group"]
    assert "inputs.managed_by_lifecycle" in group
    assert "protected-pipeline-lease" in group
    assert full_chain["concurrency"]["cancel-in-progress"] is False
