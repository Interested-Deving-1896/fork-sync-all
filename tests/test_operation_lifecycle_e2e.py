"""Offline end-to-end lifecycle fixture.

The gate below is a test double, not the production Global Authorization Gate.
The fixture performs no network, repository, runner, device or firmware action.
"""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "operation_lifecycle", ROOT / "scripts" / "operation_lifecycle.py"
)
engine = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(engine)


class FixtureAuthorizationGate:
    """Explicit test-only gate; never used by production code."""

    def authorize(self, preflight, approved=False):
        return (
            approved is True
            and preflight["status"] == "ready"
            and preflight["authority"]["operation_authorized"] is False
        )


def test_preflight_gated_fixture_and_postflight_reconcile():
    revision = "c" * 40
    operation = {
        "schema_version": "1.0", "operation_id": "offline-e2e-001",
        "operation_type": "fixture_validation", "target": "fixture://local",
        "revision": revision,
        "acceptance_criteria": ["fixture-completed", "result-recorded"],
        "policy": {"required_evidence": ["fixture-input"]},
    }
    preflight_evidence = [{
        "evidence_id": "input-1", "kind": "fixture-input", "status": "observed",
        "source": "offline-test", "revision": revision, "locator": "fixture:input",
    }]

    preflight = engine.evaluate_preflight(operation, preflight_evidence)
    assert preflight["status"] == "ready"
    assert preflight["authority"]["operation_authorized"] is False

    # The test double makes the separate authorization decision explicit.
    gate = FixtureAuthorizationGate()
    assert gate.authorize(preflight) is False
    assert gate.authorize(preflight, approved=True) is True

    # This is the only "operation": an in-memory fixture state transition.
    fixture_state = {"completed": True, "result": "ok"}

    postflight_evidence = [{
        "evidence_id": "result-1", "kind": "fixture-result", "status": "observed",
        "source": "offline-test", "revision": revision,
        "locator": "fixture:result", "summary": fixture_state["result"],
    }]
    postflight = engine.evaluate_postflight(
        operation, preflight, postflight_evidence,
        {"fixture-completed": "passed", "result-recorded": "passed"},
    )

    assert fixture_state["completed"] is True
    assert postflight["status"] == "passed"
    assert postflight["operation_id"] == preflight["operation_id"]
    assert postflight["preflight_digest"] == preflight["result_digest"]
    assert postflight["authority"]["remediation_authorized"] is False
    assert postflight["authority"]["mutation_performed"] is False
