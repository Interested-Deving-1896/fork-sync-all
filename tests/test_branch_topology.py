import importlib.util
import unittest
from urllib.parse import parse_qs, urlparse
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
        requested_pages = []

        def fixture(url, token=None):
            parsed = urlparse(url)
            if parsed.path == "/repos/owner/repo":
                return {"default_branch": "main"}
            if parsed.path == "/repos/owner/repo/pulls":
                page = int(parse_qs(parsed.query).get("page", ["0"])[0])
                requested_pages.append(page)
                if page == 1:
                    # A short page is a valid pagination terminator. Return a
                    # full page so discovery must request page two.
                    return [{"number": n, "base": {}, "head": {}} for n in range(1, 101)]
                if page == 2:
                    raise mod.DiscoveryError("page two unavailable")
            raise AssertionError(f"Unexpected discovery URL: {url}")

        with patch.object(mod, "get_json", side_effect=fixture):
            snap = mod.discover("owner/repo", None)
        self.assertEqual(requested_pages, [1, 2])
        self.assertTrue(any("page two unavailable" in x for x in snap["incomplete_reasons"]))
        self.assertEqual(len(snap["pull_requests"]), 100)
        self.assertEqual(mod.analyze(snap)["status"], "incomplete")

    def test_discover_verifies_github_compare_shape_with_exact_branch_refs(self):
        base_sha, head_sha = "a" * 40, "b" * 40
        pr_data = {"number": 9, "title": "fixture", "state": "open", "draft": False,
                   "base": {"ref": "main", "sha": base_sha, "repo": {"full_name": "owner/repo"}},
                   "head": {"ref": "feature", "sha": head_sha, "repo": {"full_name": "owner/repo"}}}

        def fixture(url, token=None):
            if url.endswith("/repos/owner/repo"):
                return {"default_branch": "main"}
            if "/pulls?" in url:
                return [pr_data]
            if url.endswith("/git/ref/heads/main"):
                return {"object": {"type": "commit", "sha": base_sha}}
            if url.endswith("/git/ref/heads/feature"):
                return {"object": {"type": "commit", "sha": head_sha}}
            if "/compare/" in url:
                return {"base_commit": {"sha": base_sha},
                        "status": "ahead", "ahead_by": 2, "behind_by": 0}
            raise AssertionError(f"Unexpected discovery URL: {url}")

        with patch.object(mod, "get_json", side_effect=fixture):
            snapshot = mod.discover("owner/repo", None)
        pr = snapshot["pull_requests"][0]
        self.assertTrue(pr["comparison_consistent"])
        self.assertEqual(pr["comparison_head_sha"], head_sha)
        self.assertEqual(pr["comparison_status"], "ahead")
        self.assertEqual(snapshot["incomplete_reasons"], [])

    def test_comparison_provider_error_becomes_unknown(self):
        pr_data = {"number": 8, "title": "fixture", "state": "open", "draft": True,
                   "base": {"ref": "main", "sha": "base", "repo": {"full_name": "owner/repo"}},
                   "head": {"ref": "feature", "sha": "head", "repo": {"full_name": "owner/repo"}}}
        def fixture(url, token=None):
            if url.endswith("/repos/owner/repo"):
                return {"default_branch": "main"}
            if "/pulls?" in url:
                return [pr_data]
            if "/git/ref/heads/" in url:
                return {"object": {"type": "commit", "sha": "a" * 40}}
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
        self.assertEqual(report["status"], "unknown")
        self.assertEqual(report["dependency_edges"], [])
        self.assertIn("comparison_unknown", [f["code"] for f in report["findings"]])

    def test_comparison_ref_change_blocks_order(self):
        p = pr(2, "main", "a", "feature", "b")
        p.update({"comparison_consistent": False, "comparison_ref_changed": True,
                  "comparison_base_sha": "c" * 40, "comparison_head_sha": "d" * 40})
        report = mod.analyze({"pull_requests": [p]})
        self.assertEqual(report["status"], "blocked")
        self.assertIn("comparison_ref_changed", [f["code"] for f in report["findings"]])
        self.assertEqual(report["advisory_topological_order"], [])



    def test_fork_compare_url_uses_owner_qualified_encoded_ref(self):
        url = mod.build_compare_url("owner/repo", "a" * 40, "contributor/repo", "feature/topic")
        self.assertEqual(url, "https://api.github.com/repos/owner/repo/compare/" +
                         "a" * 40 + "...contributor:feature%2Ftopic")

    def test_fork_compare_rejects_short_base_sha(self):
        with self.assertRaises(ValueError):
            mod.build_compare_url("owner/repo", "deadbeef", "contributor/repo", "topic")

    def test_ref_url_encodes_branch_path(self):
        self.assertEqual(mod.build_ref_url("contributor/repo", "feature/topic"),
                         "https://api.github.com/repos/contributor/repo/git/ref/heads/feature%2Ftopic")

    def test_ref_exists_requires_commit_object(self):
        self.assertTrue(mod.ref_exists({"object": {"type": "commit", "sha": "a" * 40}}))
        self.assertIsNone(mod.ref_exists({"object": {"type": "tag", "sha": "a" * 40}}))
        self.assertIsNone(mod.ref_exists({}))

    def test_ref_sha_returns_exact_commit_sha_only(self):
        self.assertEqual(mod.ref_sha({"object": {"type": "commit", "sha": "a" * 40}}), "a" * 40)
        self.assertIsNone(mod.ref_sha({"object": {"type": "tag", "sha": "a" * 40}}))
        self.assertIsNone(mod.ref_sha({"object": {"type": "commit", "sha": "short"}}))

    def test_github_compare_shape_uses_independent_head_ref_sha(self):
        # GitHub's compare response has base_commit but no head_commit field.
        result = mod.normalize_comparison(
            {"base_commit": {"sha": "a" * 40},
             "status": "ahead", "ahead_by": 2, "behind_by": 0},
            "a" * 40, "b" * 40, "owner/repo", "contributor/repo",
            "a" * 40, "b" * 40)
        self.assertTrue(result["comparison_consistent"])
        self.assertEqual(result["comparison_head_sha"], "b" * 40)
        self.assertEqual(result["comparison_status"], "ahead")

    def test_github_compare_shape_rejects_moved_head_ref(self):
        result = mod.normalize_comparison(
            {"base_commit": {"sha": "a" * 40},
             "status": "ahead", "ahead_by": 2, "behind_by": 0},
            "a" * 40, "b" * 40, "owner/repo", "contributor/repo",
            "a" * 40, "c" * 40)
        self.assertFalse(result["comparison_consistent"])
        self.assertEqual(result["comparison_status"], "unknown")

    def test_malformed_ref_evidence_remains_unknown_not_deleted_or_changed(self):
        result = mod.normalize_comparison(
            {"base_commit": {"sha": "a" * 40},
             "status": "ahead", "ahead_by": 2, "behind_by": 0},
            "a" * 40, "b" * 40, "owner/repo", "owner/repo", None, None)
        self.assertFalse(result["comparison_consistent"])
        self.assertFalse(result["comparison_ref_changed"])
        self.assertFalse(result["comparison_ref_evidence_complete"])
        self.assertEqual(result["comparison_status"], "unknown")


    def test_malformed_compare_payload_is_unknown_not_ref_changed(self):
        result = mod.normalize_comparison(
            {"status": "ahead", "ahead_by": 2, "behind_by": 0},
            "a" * 40, "b" * 40, "owner/repo", "owner/repo",
            "a" * 40, "b" * 40)
        self.assertFalse(result["comparison_consistent"])
        self.assertFalse(result["comparison_ref_changed"])
        self.assertTrue(result["comparison_ref_evidence_complete"])
        self.assertEqual(result["comparison_status"], "unknown")


    def test_fork_comparison_requires_exact_base_and_head_sha(self):
        result = mod.normalize_comparison(
            {"base_commit": {"sha": "a" * 40}, "head_commit": {"sha": "b" * 40},
             "status": "ahead", "ahead_by": 2, "behind_by": 0},
            "a" * 40, "b" * 40, "owner/repo", "contributor/repo", "a" * 40, "b" * 40)
        self.assertTrue(result["comparison_consistent"])
        self.assertEqual(result["comparison_status"], "ahead")
        self.assertEqual(result["comparison_head_repo"], "contributor/repo")

    def test_fork_comparison_moved_head_fails_closed(self):
        result = mod.normalize_comparison(
            {"base_commit": {"sha": "a" * 40},
             "status": "ahead", "ahead_by": 2, "behind_by": 0},
            "a" * 40, "b" * 40, "owner/repo", "contributor/repo", "a" * 40, "c" * 40)
        self.assertFalse(result["comparison_consistent"])
        self.assertEqual(result["comparison_status"], "unknown")
        self.assertIsNone(result["ahead_by"])

    def test_fork_comparison_rejects_boolean_or_negative_counts(self):
        for ahead, behind in ((True, 0), (1, False), (-1, 0), (0, -1), ("1", 0)):
            with self.subTest(ahead=ahead, behind=behind):
                result = mod.normalize_comparison(
                    {"base_commit": {"sha": "a" * 40}, "head_commit": {"sha": "b" * 40},
                     "status": "ahead", "ahead_by": ahead, "behind_by": behind},
                    "a" * 40, "b" * 40, "owner/repo", "contributor/repo", "a" * 40, "b" * 40)
                self.assertFalse(result["comparison_consistent"])
                self.assertEqual(result["comparison_status"], "unknown")
                self.assertIsNone(result["ahead_by"])
                self.assertIsNone(result["behind_by"])

    def test_fork_comparison_rejects_incoherent_status_counts(self):
        result = mod.normalize_comparison(
            {"base_commit": {"sha": "a" * 40}, "head_commit": {"sha": "b" * 40},
             "status": "ahead", "ahead_by": 2, "behind_by": 1},
            "a" * 40, "b" * 40, "owner/repo", "contributor/repo", "a" * 40, "b" * 40)
        self.assertFalse(result["comparison_consistent"])
        self.assertEqual(result["comparison_status"], "unknown")

if __name__ == "__main__":
    unittest.main()
