import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("branch_topology", ROOT / "scripts" / "branch-topology.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


class ForkCompareAdapterTests(unittest.TestCase):
    BASE = "a" * 40
    HEAD = "b" * 40

    def response(self, base=None, head=None):
        return {
            "base_commit": {"sha": base or self.BASE},
            "head_commit": {"sha": head or self.HEAD},
            "merge_base_commit": {"sha": "c" * 40},
            "status": "ahead",
            "ahead_by": 4,
            "behind_by": 0,
        }

    def test_builds_owner_qualified_fork_compare_url(self):
        url = MODULE.build_compare_url(
            "upstream/project", self.BASE, "contributor/project", "feature/topic"
        )
        self.assertEqual(
            url,
            f"https://api.github.com/repos/upstream/project/compare/{self.BASE}...contributor:feature/topic",
        )

    def test_rejects_short_or_non_hex_base_sha(self):
        with self.assertRaises(ValueError):
            MODULE.build_compare_url("upstream/project", "deadbeef", "fork/project", "topic")

    def test_accepts_exact_base_and_fork_head_sha(self):
        result = MODULE.normalize_comparison(
            self.response(), self.BASE, self.HEAD, "upstream/project", "contributor/project"
        )
        self.assertTrue(result["comparison_consistent"])
        self.assertEqual(result["comparison_status"], "ahead")
        self.assertEqual(result["ahead_by"], 4)
        self.assertEqual(result["comparison_head_repo"], "contributor/project")

    def test_rejects_moved_base_sha(self):
        result = MODULE.normalize_comparison(
            self.response(base="d" * 40), self.BASE, self.HEAD,
            "upstream/project", "contributor/project"
        )
        self.assertFalse(result["comparison_consistent"])
        self.assertEqual(result["comparison_status"], "unknown")
        self.assertIsNone(result["ahead_by"])

    def test_rejects_moved_fork_head_sha(self):
        result = MODULE.normalize_comparison(
            self.response(head="e" * 40), self.BASE, self.HEAD,
            "upstream/project", "contributor/project"
        )
        self.assertFalse(result["comparison_consistent"])
        self.assertEqual(result["comparison_status"], "unknown")
        self.assertIsNone(result["behind_by"])

    def test_rejects_missing_compare_payload(self):
        result = MODULE.normalize_comparison(
            {}, self.BASE, self.HEAD, "upstream/project", "contributor/project"
        )
        self.assertFalse(result["comparison_consistent"])
        self.assertEqual(result["comparison_status"], "unknown")


if __name__ == "__main__":
    unittest.main()
