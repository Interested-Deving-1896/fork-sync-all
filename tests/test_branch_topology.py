import importlib.util
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("branch_topology", "scripts/branch-topology.py")
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)


def pr(number, base_ref, base_sha, head_ref, head_sha, comparison="identical", repo="owner/repo"):
    return {"number": number, "base_repo": repo, "base_ref": base_ref, "base_sha": base_sha,
            "head_repo": repo, "head_ref": head_ref, "head_sha": head_sha,
            "base_ref_exists": True, "head_ref_exists": True,
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


    def test_metadata_error_is_preserved_as_incomplete_snapshot(self):
        def fixture(url, token=None):
            if url.endswith("/pulls?state=open&per_page=100&page=1"):
                return []
            raise mod.DiscoveryError("metadata unavailable")
        with patch.object(mod, "get_json", side_effect=fixture):
            snap = mod.discover("owner/repo", None)
        self.assertIsNone(snap["default_branch"])
        self.assertTrue(any("Repository metadata unavailable" in x for x in snap["incomplete_reasons"]))
        self.assertEqual(mod.analyze(snap)["status"], "incomplete")

    def test_pagination_error_is_preserved(self):
        def fixture(url, token=None):
            if url.endswith("/repos/owner/repo"):
                return {"default_branch": "main"}
            if "page=1" in url:
                return [{"number": 7, "base": {}, "head": {}}]
            raise mod.DiscoveryError("page two unavailable")
        with patch.object(mod, "get_json", side_effect=fixture):
            snap = mod.discover("owner/repo", None)
        self.assertTrue(any("page two unavailable" in x for x in snap["incomplete_reasons"]))
        self.assertEqual(len(snap["pull_requests"]), 1)
        self.assertEqual(mod.analyze(snap)["status"], "incomplete")

    def test_comparison_provider_error_becomes_unknown(self):
        pr_data = {"number": 8, "title": "fixture", "state": "open", "draft": True,
                   "base": {"ref": "main", "sha": "base", "repo": {"full_name": "owner/repo"}},
                   "head": {"ref": "feature", "sha": "head", "repo": {"full_name": "owner/repo"}}}
        def fixture(url, token=None):
            if url.endswith("/repos/owner/repo"):
                return {"default_branch": "main"}
            if "/pulls?" in url:
                return [pr_data]
            raise mod.DiscoveryError("comparison endpoint unavailable")
        with patch.object(mod, "get_json", side_effect=fixture):
            snap = mod.discover("owner/repo", None)
        self.assertEqual(snap["pull_requests"][0]["comparison_status"], "unknown")
        self.assertTrue(any("comparison unavailable" in x for x in snap["incomplete_reasons"]))
        self.assertEqual(mod.analyze(snap)["status"], "incomplete")


    def test_deleted_head_ref_blocks_order(self):
        p = pr(2, "main", "a", "feature", "b")
        p["head_ref_exists"] = False
        report = mod.analyze({"pull_requests": [p]})
        self.assertEqual(report["status"], "blocked")
        self.assertIn("missing_ref", [f["code"] for f in report["findings"]])
        self.assertEqual(report["advisory_topological_order"], [])

    def test_unknown_ref_existence_is_not_treated_as_present(self):
        p = pr(2, "main", "a", "feature", "b")
        p.pop("head_ref_exists")
        report = mod.analyze({"pull_requests": [p]})
        self.assertEqual(report["status"], "unknown")
        self.assertIn("ref_existence_unknown", [f["code"] for f in report["findings"]])

    def test_cross_repository_edge_is_distinct_and_comparison_unknown(self):
        p = pr(3, "main", "a", "feature", "b", repo="fork/repo")
        p["base_repo"] = "owner/repo"
        p["comparison_status"] = "unknown"
        report = mod.analyze({"pull_requests": [p]})
        self.assertEqual(report["status"], "incomplete")
        self.assertEqual(report["dependency_edges"], [])
        self.assertIn("comparison_unknown", [f["code"] for f in report["findings"]])

    def test_comparison_ref_change_blocks_order(self):
        p = pr(2, "main", "a", "feature", "b")
        p.update({"comparison_consistent": False, "comparison_base_sha": "new-a",
                  "comparison_head_sha": "new-b"})
        report = mod.analyze({"pull_requests": [p]})
        self.assertEqual(report["status"], "blocked")
        self.assertIn("comparison_ref_changed", [f["code"] for f in report["findings"]])
        self.assertEqual(report["advisory_topological_order"], [])


if __name__ == "__main__":
    unittest.main()
