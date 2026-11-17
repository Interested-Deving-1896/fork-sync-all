"""Offline tests for safe, deterministic FSA dry-run planning."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from fsa_stack_linkage import LinkageError, load_registry  # noqa: E402
from fsa_stack_linkage_plan import build_plan  # noqa: E402


def registry() -> dict:
    return {
        "schema_version": 1, "registry_id": "fsa.stack-linkage", "mode": "declaration-only",
        "nodes": [
            {"id": "fsa.source", "kind": "engine", "owner": "fsa", "authority": "source",
             "lifecycle": "existing", "evidence": ["issue:1"]},
            {"id": "fsa.target", "kind": "repository", "owner": "fsa", "authority": "target",
             "lifecycle": "existing", "evidence": ["issue:2"]},
        ],
        "edges": [],
    }


class DryRunPlanTests(unittest.TestCase):
    def plan(self, **overrides):
        args = dict(source="fsa.source", target="fsa.target", artifacts=["documentation"],
                    compatibility="compatible", owner="fsa-stack-linkage")
        args.update(overrides)
        return build_plan(registry(), **args)

    def test_compatible_route_is_only_a_candidate(self):
        plan = self.plan()
        self.assertEqual(plan["status"], "candidate")
        self.assertEqual(plan["mode"], "dry-run")
        self.assertFalse(plan["execution_permitted"])
        self.assertFalse(plan["write_authority"])
        self.assertEqual(plan["side_effects"], [])

    def test_unknown_or_incompatible_routes_are_blocked(self):
        for state in ("unknown", "incompatible"):
            with self.subTest(state=state):
                plan = self.plan(compatibility=state)
                self.assertEqual(plan["status"], "blocked")
                self.assertTrue(plan["reasons"])

    def test_output_is_deterministic_and_sorts_artifact_classes(self):
        first = self.plan(artifacts=["workflow", "documentation"])
        second = self.plan(artifacts=["documentation", "workflow"])
        self.assertEqual(first, second)
        self.assertEqual(first["route"]["artifact_classes"], ["documentation", "workflow"])

    def test_unknown_nodes_and_same_endpoint_fail_closed(self):
        with self.assertRaisesRegex(LinkageError, "unknown target"):
            self.plan(target="fsa.missing")
        with self.assertRaisesRegex(LinkageError, "different nodes"):
            self.plan(target="fsa.source")

    def test_invalid_artifacts_direction_policy_and_owner_fail_closed(self):
        cases = [
            {"artifacts": []}, {"artifacts": ["secrets"]},
            {"direction": "reverse"}, {"conflict_policy": "overwrite"},
            {"owner": " "},
        ]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(LinkageError):
                self.plan(**case)

    def test_cli_emits_non_executable_plan(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "fsa_stack_linkage_plan.py"),
             "--source", "fsa.stack-linkage-engine", "--target", "fsa.branch-topology",
             "--artifact", "documentation", "--compatibility", "unknown",
             "--owner", "fsa-stack-linkage"],
            cwd=ROOT, capture_output=True, text=True, check=False,
        )
        # The real registry is used for an integration smoke test by CI.
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual(plan["status"], "blocked")
        self.assertFalse(plan["execution_permitted"])
        self.assertFalse(plan["write_authority"])


if __name__ == "__main__":
    unittest.main()
