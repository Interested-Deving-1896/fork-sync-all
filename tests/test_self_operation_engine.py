import json
import tempfile
import unittest
from pathlib import Path

from scripts.self_operation_engine import (
    ExecutionPolicy, JsonlJournal, Operation, PolicyDenied,
    SelfOperationEngine, SelfOperationError, main, topological_plan,
)


class FakeAdapter:
    sandbox = True

    def __init__(self, *, capabilities=None, verified=True):
        self._capabilities = capabilities or {"repo.inspect", "repo.seed"}
        self.verified = verified
        self.writes = []
        self.inspections = 0

    def capabilities(self):
        return set(self._capabilities)

    def inspect(self, operation):
        self.inspections += 1
        return {"target": operation.target, "access_token": "must-not-be-journaled", "state": "present"}

    def execute(self, operation, idempotency_key):
        self.writes.append((operation.operation_id, idempotency_key))
        return {"accepted": True, "password": "must-not-be-journaled"}

    def verify(self, operation, execution):
        return {"verified": self.verified, "read_back": {"target": operation.target}}

    def reconcile(self, operation, execution):
        return {"status": "manual_review", "credential": "redact-me"}


class SelfOperationEngineTests(unittest.TestCase):
    def setUp(self):
        self.ops = [
            Operation("seed", "repo.seed", "sandbox/repo", ("inspect",), True, {"files": ["README.md"]}),
            Operation("inspect", "repo.inspect", "sandbox/repo"),
        ]

    def test_plan_is_deterministic_and_dependency_ordered(self):
        plan = topological_plan(self.ops)
        self.assertEqual([op.operation_id for op in plan], ["inspect", "seed"])
        self.assertEqual([op.operation_id for op in plan], [op.operation_id for op in topological_plan(self.ops)])

    def test_missing_dependency_and_cycle_fail_closed(self):
        with self.assertRaises(SelfOperationError):
            topological_plan([Operation("a", "x", "t", ("missing",))])
        with self.assertRaises(SelfOperationError):
            topological_plan([Operation("a", "x", "t", ("b",)), Operation("b", "x", "t", ("a",))])

    def test_plan_mode_performs_no_writes(self):
        adapter = FakeAdapter()
        report = SelfOperationEngine(adapter).run(self.ops, mode="plan")
        self.assertEqual(report.status, "planned")
        self.assertEqual(adapter.writes, [])
        self.assertEqual(adapter.inspections, 0)

    def test_audit_mode_is_read_only(self):
        adapter = FakeAdapter()
        report = SelfOperationEngine(adapter).run(self.ops, mode="audit")
        self.assertEqual(report.status, "audited")
        self.assertEqual(adapter.writes, [])
        self.assertEqual(adapter.inspections, 2)

    def test_sandbox_requires_authorization_and_target_allowlist(self):
        adapter = FakeAdapter()
        denied = SelfOperationEngine(adapter).run(self.ops, mode="sandbox")
        self.assertEqual(denied.status, "failed")
        self.assertIn("denied", {item.status for item in denied.results})
        self.assertEqual(adapter.writes, [])
        adapter.inspections = 0
        allowed = SelfOperationEngine(adapter).run(
            self.ops, mode="sandbox",
            policy=ExecutionPolicy(mutation_authorized=True, allowed_targets=frozenset({"sandbox/repo"})),
        )
        self.assertEqual(allowed.status, "verified")
        self.assertEqual(len(adapter.writes), 1)
        self.assertEqual(adapter.inspections, 1)

    def test_live_mode_is_not_available(self):
        with self.assertRaises(PolicyDenied):
            SelfOperationEngine(FakeAdapter()).run(self.ops, mode="live")

    def test_non_sandbox_adapter_cannot_execute_sandbox_mode(self):
        adapter = FakeAdapter()
        adapter.sandbox = False
        report = SelfOperationEngine(adapter).run(
            self.ops, mode="sandbox",
            policy=ExecutionPolicy(mutation_authorized=True, allowed_targets=frozenset({"sandbox/repo"})),
        )
        self.assertEqual(report.status, "failed")
        self.assertEqual(adapter.writes, [])

    def test_missing_capability_is_reported_unsupported(self):
        adapter = FakeAdapter(capabilities={"repo.inspect"})
        report = SelfOperationEngine(adapter).run(self.ops, mode="plan")
        self.assertEqual(report.status, "blocked")
        self.assertIn("unsupported", {item.status for item in report.results})

    def test_failed_readback_is_not_success(self):
        adapter = FakeAdapter(verified=False)
        report = SelfOperationEngine(adapter).run(
            self.ops, mode="sandbox",
            policy=ExecutionPolicy(mutation_authorized=True, allowed_targets=frozenset({"sandbox/repo"})),
        )
        self.assertEqual(report.status, "failed")
        self.assertIn("verification_failed", {item.status for item in report.results})

    def test_dependency_failure_blocks_downstream(self):
        class FailingAdapter(FakeAdapter):
            def execute(self, operation, idempotency_key):
                if operation.operation_id == "first":
                    raise TimeoutError("ambiguous provider outcome")
                return super().execute(operation, idempotency_key)

        adapter = FailingAdapter()
        operations = [
            Operation("first", "repo.seed", "sandbox/repo", mutating=True),
            Operation("second", "repo.seed", "sandbox/repo", ("first",), mutating=True),
        ]
        report = SelfOperationEngine(adapter).run(
            operations, mode="sandbox",
            policy=ExecutionPolicy(mutation_authorized=True, allowed_targets=frozenset({"sandbox/repo"})),
        )
        self.assertEqual(report.status, "failed")
        self.assertEqual([item.status for item in report.results], ["failed", "blocked"])
        self.assertEqual(adapter.writes, [])

    def test_adapter_exception_is_reconciled_without_persisting_payload(self):
        class AmbiguousAdapter(FakeAdapter):
            def execute(self, operation, idempotency_key):
                raise TimeoutError("provider returned secret=do-not-leak")
            def reconcile(self, operation, execution):
                return {"status": "manual_review", "access_token": "do-not-leak"}

        adapter = AmbiguousAdapter()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "journal.jsonl"
            report = SelfOperationEngine(adapter).run(
                [Operation("create", "repo.seed", "sandbox/repo", mutating=True)],
                mode="sandbox",
                policy=ExecutionPolicy(mutation_authorized=True, allowed_targets=frozenset({"sandbox/repo"})),
                journal=JsonlJournal(path),
            )
            contents = path.read_text()
            self.assertEqual(report.status, "failed")
            self.assertNotIn("do-not-leak", contents)
            self.assertIn("manual_review", contents)

    def test_stale_plan_is_rejected(self):
        with self.assertRaises(PolicyDenied):
            SelfOperationEngine(FakeAdapter()).run(self.ops, mode="plan", expected_plan_digest="stale")

    def test_journal_redacts_secrets_and_is_owner_only(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "journal.jsonl"
            journal = JsonlJournal(path)
            journal.append({"event": "test", "access_token": "top-secret", "nested": {"password": "pw"}})
            record = json.loads(path.read_text())
            self.assertEqual(record["access_token"], "[REDACTED]")
            self.assertEqual(record["nested"]["password"], "[REDACTED]")
            self.assertNotIn("top-secret", path.read_text())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_cli_rejects_audit_without_a_real_adapter(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps({"version": 1, "operations": []}))
            with self.assertRaises(SystemExit) as raised:
                main([str(path), "--mode", "audit"])
            self.assertEqual(raised.exception.code, 2)

    def test_manifest_validation(self):
        from scripts.self_operation_engine import _load_operations
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps({"version": 1, "operations": [{"id": "check", "capability": "repo.inspect", "target": "self"}]}))
            self.assertEqual(_load_operations(path)[0].operation_id, "check")


if __name__ == "__main__":
    unittest.main()
