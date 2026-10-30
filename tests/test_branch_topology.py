import importlib.util
import unittest

SPEC = importlib.util.spec_from_file_location("branch_topology", "scripts/branch-topology.py")
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)


def pr(number, base_ref, base_sha, head_ref, head_sha, comparison="identical", repo="owner/repo"):
    return {"number": number, "base_repo": repo, "base_ref": base_ref, "base_sha": base_sha,
            "head_repo": repo, "head_ref": head_ref, "head_sha": head_sha,
            "draft": True, "comparison_status": comparison, "ahead_by": 1, "behind_by": 0}


class TopologyTests(unittest.TestCase):
    def test_linear_stack_and_order(self):
        snap = {"repository": "owner/repo", "pull_requests": [
            pr(2, "main", "a", "feature-a", "b"),
            pr(3, "feature-a", "b", "feature-b", "c")]}
        report = mod.analyze(snap)
        self.assertEqual(report["status"], "complete")
        self.assertEqual(report["advisory_topological_order"], [2, 3])
        self.assertEqual([(e["from_pr"], e["to_pr"]) for e in report["dependency_edges"]], [(2, 3)])

    def test_stale_base_sha(self):
        report = mod.analyze({"pull_requests": [
            pr(2, "main", "a", "feature-a", "b"),
            pr(3, "feature-a", "old-b", "feature-b", "c")]})
        self.assertIn("stale_base_sha", [f["code"] for f in report["findings"]])

    def test_diverged_is_advisory_only(self):
        report = mod.analyze({"pull_requests": [pr(2, "main", "a", "feature", "b", "diverged")]})
        self.assertIn("base_update_candidate", [f["code"] for f in report["findings"]])
        self.assertTrue(report["read_only"])

    def test_unrelated_prs_have_no_edge(self):
        report = mod.analyze({"pull_requests": [
            pr(2, "main", "a", "feature-a", "b"),
            pr(3, "main", "a", "feature-b", "c")]})
        self.assertEqual(report["dependency_edges"], [])

    def test_ambiguous_parent_blocks_order(self):
        report = mod.analyze({"pull_requests": [
            pr(2, "main", "a", "same-branch", "b"),
            pr(3, "main", "a", "same-branch", "c"),
            pr(4, "same-branch", "b", "child", "d")]})
        self.assertEqual(report["status"], "blocked")
        self.assertEqual(report["advisory_topological_order"], [])

    def test_cycle_blocks_order(self):
        report = mod.analyze({"pull_requests": [
            pr(2, "branch-b", "c", "branch-a", "b"),
            pr(3, "branch-a", "b", "branch-b", "c")]})
        self.assertEqual(report["status"], "blocked")
        self.assertIn("dependency_cycle", [f["code"] for f in report["findings"]])

    def test_incomplete_snapshot_fails_closed(self):
        report = mod.analyze({"pull_requests": [pr(2, "main", "a", "feature", "b")],
                              "incomplete_reasons": ["page two unavailable"]})
        self.assertEqual(report["status"], "incomplete")
        self.assertEqual(report["advisory_topological_order"], [])

    def test_missing_comparison_is_unknown(self):
        p = pr(2, "main", "a", "feature", "b")
        p.pop("comparison_status")
        report = mod.analyze({"pull_requests": [p]})
        self.assertEqual(report["status"], "unknown")

    def test_deterministic_report(self):
        snap = {"repository": "owner/repo", "pull_requests": [
            pr(3, "main", "a", "feature-b", "c"), pr(2, "main", "a", "feature-a", "b")]}
        self.assertEqual(mod.analyze(snap), mod.analyze(snap))


if __name__ == "__main__":
    unittest.main()
