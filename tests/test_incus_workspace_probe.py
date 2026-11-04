from __future__ import annotations

import importlib.util
import pathlib
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "incus-workspace-probe.py"
SPEC = importlib.util.spec_from_file_location("incus_workspace_probe", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class IncusWorkspaceProbeTests(unittest.TestCase):
    def test_missing_client_is_unavailable_and_does_not_run_commands(self):
        calls = []
        result = MODULE.probe(which=lambda _: None, run=lambda *args: calls.append(args))
        self.assertEqual(result["status"], "unavailable")
        self.assertEqual(calls, [])
        self.assertFalse(result["safety"]["mutations_attempted"])

    def test_working_daemon_does_not_claim_create_or_exec_are_safe(self):
        calls = []

        def fake_run(command, timeout):
            calls.append((command, timeout))
            return {"status": "available", "output": "ok"}

        result = MODULE.probe(which=lambda _: "/usr/bin/incus", run=fake_run)
        self.assertEqual(result["status"], "available")
        self.assertEqual(result["capabilities"]["inspect_workspace"], "available")
        self.assertEqual(result["capabilities"]["create_workspace"], "requires_policy_review")
        self.assertEqual(result["capabilities"]["exec_workspace"], "requires_policy_review")
        self.assertEqual([call[0][1:] for call in calls], [["version"], ["info", "--format=json"]])
        self.assertTrue(all(call[1] == 5 for call in calls))
        self.assertFalse(result["safety"]["resources_created_or_deleted"])

    def test_daemon_failure_is_not_healthy(self):
        def fake_run(command, timeout):
            if command[1] == "info":
                return {"status": "unavailable", "error": "daemon unavailable"}
            return {"status": "available", "output": "client version"}

        result = MODULE.probe(which=lambda _: "/usr/bin/incus", run=fake_run)
        self.assertEqual(result["status"], "unavailable")
        self.assertEqual(result["capabilities"]["inspect_workspace"], "unknown")

    def test_unknown_observation_stays_unknown(self):
        result = MODULE.probe(
            which=lambda _: "/usr/bin/incus",
            run=lambda command, timeout: {"status": "unknown", "error": "timeout"},
        )
        self.assertEqual(result["status"], "unknown")
        self.assertEqual(result["capabilities"]["create_workspace"], "unknown")


if __name__ == "__main__":
    unittest.main()
