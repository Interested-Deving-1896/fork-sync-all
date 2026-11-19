"""Regression tests for the fail-closed critical-deploy-all job graph."""

from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/critical-deploy-all.yml"


def _jobs() -> dict:
    with WORKFLOW.open() as workflow_file:
        workflow = yaml.safe_load(workflow_file)
    return workflow["jobs"]


def test_downstream_jobs_require_successful_dependencies() -> None:
    jobs = _jobs()
    expected_dependencies = {
        "quota-checkpoint-1": "deploy-source",
        "deploy-osp": "quota-checkpoint-1",
        "deploy-ooc": "quota-checkpoint-1",
        "quota-checkpoint-2": ["deploy-osp", "deploy-ooc"],
        "deploy-gitlab": "quota-checkpoint-2",
    }

    for job_name, expected_needs in expected_dependencies.items():
        job = jobs[job_name]
        assert job["needs"] == expected_needs
        assert "if" not in job, (
            f"{job_name} must use GitHub Actions' default success() dependency "
            "guard instead of overriding it"
        )


def test_only_finalizer_overrides_dependency_status() -> None:
    jobs = _jobs()
    finalizer = jobs["release-pipeline"]

    assert finalizer["if"] == "always()"
    assert finalizer["needs"] == [
        "deploy-source",
        "quota-checkpoint-1",
        "deploy-osp",
        "deploy-ooc",
        "quota-checkpoint-2",
        "deploy-gitlab",
    ]
    assert all(
        "always()" not in str(job.get("if", ""))
        for name, job in jobs.items()
        if name != "release-pipeline"
    )


def test_lease_is_released_once_by_the_finalizer() -> None:
    jobs = _jobs()
    release_calls = []

    for job_name, job in jobs.items():
        for step in job.get("steps", []):
            if "pipeline_guard_end" in step.get("run", ""):
                release_calls.append((job_name, step["name"]))

    assert release_calls == [
        ("release-pipeline", "Release pipeline (clear FLUSH_ACTIVE)")
    ]
