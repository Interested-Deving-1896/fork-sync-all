"""Unit tests for the staged, non-destructive mirror planner and guardrails."""
import importlib.util
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).parents[1]
MODULE_PATH = ROOT / "scripts" / "mirror_chain_push.py"
SPEC = importlib.util.spec_from_file_location("mirror_chain_push", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MirrorPlanTests(unittest.TestCase):
    def setUp(self):
        self.ancestor = lambda old, new: (old, new) in {
            ("a", "b"), ("a", "c"), ("b", "c")
        }

    def test_missing_branch_is_created(self):
        plan = MODULE.plan_refs({"main": "a"}, {}, {}, {}, self.ancestor)
        self.assertEqual(plan[0]["action"], "create")

    def test_fast_forward_is_allowed(self):
        plan = MODULE.plan_refs({"main": "b"}, {"main": "a"}, {}, {},
                                self.ancestor)
        self.assertEqual(plan[0]["action"], "fast_forward")

    def test_divergent_branch_blocks(self):
        plan = MODULE.plan_refs({"main": "x"}, {"main": "a"}, {}, {},
                                self.ancestor)
        self.assertEqual(plan[0]["action"], "blocked_divergence")

    def test_target_ahead_is_preserved(self):
        plan = MODULE.plan_refs({"main": "a"}, {"main": "b"}, {}, {},
                                self.ancestor)
        self.assertEqual(plan[0]["action"], "target_ahead_preserve")

    def test_conflicting_tag_blocks(self):
        plan = MODULE.plan_refs({}, {}, {"v1": "new"}, {"v1": "old"},
                                self.ancestor)
        self.assertEqual(plan[0]["action"], "blocked_tag_conflict")

    def test_matching_tag_is_unchanged(self):
        plan = MODULE.plan_refs({}, {}, {"v1": "same"}, {"v1": "same"},
                                self.ancestor)
        self.assertEqual(plan[0]["action"], "unchanged")

    def test_target_only_refs_are_not_in_plan(self):
        plan = MODULE.plan_refs({}, {"legacy": "a"}, {}, {"old": "b"},
                                self.ancestor)
        self.assertEqual(plan, [])


class SourceToOSPGuardTests(unittest.TestCase):
    def test_live_mode_is_rejected_before_network_access(self):
        env = os.environ.copy()
        env.update({
            "GH_TOKEN": "test-token",
            "UPSTREAM_OWNER": "source",
            "OSP_ORG": "mirror",
            "DRY_RUN": "false",
        })
        result = subprocess.run(
            ["bash", str(ROOT / "scripts" / "mirror-to-osp.sh")],
            cwd=ROOT, env=env, text=True, capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("live source-to-OSP mirroring is disabled", result.stderr)


if __name__ == "__main__":
    unittest.main()
