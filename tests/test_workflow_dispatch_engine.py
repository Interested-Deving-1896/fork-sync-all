import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from scripts.workflow_dispatch_engine import (
    DispatchError, WorkflowPolicy, dispatch_workflow, load_policy, validate_request,
)


class FakeAdapter:
    def __init__(self):
        self.calls = []

    def dispatch(self, repository, workflow, ref, inputs):
        self.calls.append((repository, workflow, ref, dict(inputs)))

    def find_recent_run(self, repository, workflow, ref, not_before):
        return {"id": 123, "status": "queued", "conclusion": None}


def policy(**overrides):
    values = dict(
        repository="Interested-Deving-1896/fork-sync-all",
        workflow=".github/workflows/example.yml",
        allowed_refs=("main",),
        enabled=True,
        confirmation_input="confirm",
        confirmation_value="RUN-ONCE",
        required_inputs=("mode",),
        input_allowlists={"mode": ("safe", "check")},
        protected=True,
    )
    values.update(overrides)
    return WorkflowPolicy(**values)


class WorkflowDispatchEngineTests(unittest.TestCase):
    def test_policy_load_is_exact_and_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "policy.json"
            path.write_text(json.dumps({
                "version": 1,
                "workflows": [{
                    "repository": "org/repo", "workflow": ".github/workflows/ci.yml",
                    "allowed_refs": ["main"], "enabled": False,
                }],
            }))
            loaded = load_policy(path, "org/repo", "ci.yml")
            self.assertFalse(loaded.enabled)
            with self.assertRaises(DispatchError):
                load_policy(path, "org/repo", "other.yml")

    def test_dry_run_validates_without_dispatching(self):
        adapter = FakeAdapter()
        result = dispatch_workflow(
            policy(), adapter, "main",
            {"mode": "safe", "confirm": "RUN-ONCE"},
        )
        self.assertTrue(result["accepted"])
        self.assertEqual(result["mode"], "dry-run")
        self.assertEqual(adapter.calls, [])

    def test_live_dispatch_requires_both_authorization_and_confirmation(self):
        with self.assertRaises(DispatchError):
            validate_request(policy(), "main", {"mode": "safe", "confirm": "RUN-ONCE"},
                            True, None)
        with self.assertRaises(DispatchError):
            validate_request(policy(), "main", {"mode": "safe", "confirm": "RUN-ONCE"},
                            True, "wrong")

    def test_live_dispatch_returns_correlated_run_when_unique(self):
        adapter = FakeAdapter()
        result = dispatch_workflow(
            policy(), adapter, "main",
            {"mode": "safe", "confirm": "RUN-ONCE"},
            authorize=True, confirmation="RUN-ONCE",
            now=datetime(2026, 11, 4, tzinfo=timezone.utc),
        )
        self.assertTrue(result["accepted"])
        self.assertEqual(result["mode"], "live")
        self.assertEqual(result["run"]["id"], 123)
        self.assertEqual(len(adapter.calls), 1)

    def test_disabled_policy_ref_and_unknown_input_rejected(self):
        with self.assertRaises(DispatchError):
            validate_request(policy(enabled=False), "main",
                             {"mode": "safe", "confirm": "RUN-ONCE"}, False, None)
        with self.assertRaises(DispatchError):
            validate_request(policy(), "feature/other",
                             {"mode": "safe", "confirm": "RUN-ONCE"}, False, None)
        with self.assertRaises(DispatchError):
            validate_request(policy(), "main",
                             {"mode": "safe", "confirm": "RUN-ONCE", "token": "secret"},
                             False, None)

    def test_required_input_and_allowlist_enforced(self):
        with self.assertRaises(DispatchError):
            validate_request(policy(), "main", {"confirm": "RUN-ONCE"}, False, None)
        with self.assertRaises(DispatchError):
            validate_request(policy(), "main",
                             {"mode": "unsafe", "confirm": "RUN-ONCE"}, False, None)

    def test_confirmation_input_must_match_exactly(self):
        with self.assertRaises(DispatchError):
            validate_request(policy(), "main",
                             {"mode": "safe", "confirm": "run-once"}, False, None)

    def test_input_values_are_not_returned_in_audit_result(self):
        adapter = FakeAdapter()
        result = dispatch_workflow(
            policy(), adapter, "main",
            {"mode": "safe", "confirm": "RUN-ONCE"},
        )
        self.assertNotIn("inputs", result)
        self.assertNotIn("RUN-ONCE", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
