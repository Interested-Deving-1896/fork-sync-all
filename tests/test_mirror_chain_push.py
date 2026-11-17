"""Unit tests for the staged, non-destructive mirror planner."""
import importlib.util
from pathlib import Path
import unittest

MODULE_PATH = Path(__file__).parents[1] / "scripts" / "mirror_chain_push.py"
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


if __name__ == "__main__":
    unittest.main()
