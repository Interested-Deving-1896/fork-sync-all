import io
import json
import urllib.error
import tempfile
import unittest
from unittest.mock import patch
from datetime import datetime, timezone
from pathlib import Path

from scripts.workflow_dispatch_engine import (
    DispatchError, GitHubActionsAdapter, WorkflowPolicy, dispatch_workflow,
    load_policy, validate_request,
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
            loaded = load_policy(path, "org/repo", ".github/workflows/ci.yml")
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

    def test_policy_rejects_duplicate_registration_and_malformed_allowlist(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "policy.json"
            entry = {
                "repository": "org/repo",
                "workflow": ".github/workflows/ci.yml",
                "allowed_refs": ["main"],
                "enabled": True,
                "required_inputs": [],
                "input_allowlists": {},
            }
            path.write_text(json.dumps({"version": 1, "workflows": [entry, entry]}))
            with self.assertRaises(DispatchError):
                load_policy(path, "org/repo", ".github/workflows/ci.yml")

            entry["input_allowlists"] = {"mode": "safe"}
            path.write_text(json.dumps({"version": 1, "workflows": [entry]}))
            with self.assertRaises(DispatchError):
                load_policy(path, "org/repo", ".github/workflows/ci.yml")

    def test_live_dispatch_requires_policy_defined_confirmation(self):
        unconfirmed_policy = policy(confirmation_input=None, confirmation_value=None)
        with self.assertRaises(DispatchError):
            validate_request(
                unconfirmed_policy, "main", {"mode": "safe"},
                True, None,
            )

    def test_github_adapter_dispatches_only_to_registered_workflow_endpoint(self):
        class Response:
            status = 204

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self):
                return b""

        captured = {}

        def fake_urlopen(request, timeout):
            captured["url"] = request.full_url
            captured["method"] = request.get_method()
            captured["headers"] = dict(request.header_items())
            captured["payload"] = json.loads(request.data.decode("utf-8"))
            captured["timeout"] = timeout
            return Response()

        adapter = GitHubActionsAdapter("test-runtime-token")
        with patch("urllib.request.urlopen", side_effect=fake_urlopen):
            adapter.dispatch(
                "org/repo", ".github/workflows/example.yml", "main",
                {"confirm": "RUN-ONCE"},
            )
        self.assertTrue(captured["url"].endswith("/repos/org/repo/actions/workflows/example.yml/dispatches"))
        self.assertEqual(captured["method"], "POST")
        self.assertEqual(captured["payload"], {
            "ref": "main", "inputs": {"confirm": "RUN-ONCE"}
        })
        self.assertEqual(captured["timeout"], 20)
        self.assertNotIn("test-runtime-token", captured["url"])
        self.assertNotIn("test-runtime-token", json.dumps(captured["payload"]))

    def test_github_adapter_does_not_expose_provider_error_body(self):
        adapter = GitHubActionsAdapter("test-runtime-token")
        error = urllib.error.HTTPError(
            "https://api.github.com/dispatch", 403, "Forbidden", {},
            io.BytesIO(b"private-provider-response-token"),
        )
        with patch("urllib.request.urlopen", side_effect=error):
            with self.assertRaises(DispatchError) as raised:
                adapter.dispatch("org/repo", "123", "main", {})
        self.assertNotIn("private-provider-response-token", str(raised.exception))
        self.assertNotIn("test-runtime-token", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
