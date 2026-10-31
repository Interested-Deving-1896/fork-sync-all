"""Unit tests for scripts.merge_strategy_classifier (stdlib unittest)."""
import importlib.util
import pathlib
import unittest

MODULE_PATH = pathlib.Path(__file__).parents[1] / "scripts" / "merge_strategy_classifier.py"
spec = importlib.util.spec_from_file_location("classifier", MODULE_PATH)
classifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(classifier)


def base(**updates):
    item = {
        "provider": "github",
        "repository": "owner/repo",
        "id": 17,
        "source_branch": "feature",
        "target_branch": "main",
        "commit_count": 1,
        "discovery_complete": True,
        "topology_complete": True,
        "dependency_evidence_complete": True,
        "independent": True,
        "stacked": False,
        "checks": {"required": "success"},
        "approval_required": False,
        "approved": True,
        "mergeable": True,
    }
    item.update(updates)
    return item


class ClassifierTests(unittest.TestCase):
    def test_independent_single_commit_squashes(self):
        self.assertEqual(classifier.classify(base())["strategy"], "squash")

    def test_clean_independent_series_rebases(self):
        item = base(commit_count=4, commits_clean=True)
        self.assertEqual(classifier.classify(item)["strategy"], "rebase")

    def test_stacked_preserves_topology(self):
        self.assertEqual(classifier.classify(base(stacked=True))["strategy"], "merge_commit")

    def test_integration_history_merges(self):
        self.assertEqual(classifier.classify(base(integration_change=True))["strategy"], "merge_commit")

    def test_pending_required_checks_hold(self):
        result = classifier.classify(base(checks={"required": "pending"}))
        self.assertEqual(result["strategy"], "hold")
        self.assertEqual(result["readiness"], "blocked")

    def test_missing_required_check_evidence_fails_closed(self):
        result = classifier.classify(base(checks={}))
        self.assertEqual(result["strategy"], "hold")
        self.assertEqual(result["readiness"], "insufficient_evidence")

    def test_conflict_holds(self):
        self.assertIn("merge_conflict", classifier.classify(base(mergeable=False))["blockers"])

    def test_missing_review_holds(self):
        result = classifier.classify(base(approval_required=True, approved=False))
        self.assertEqual(result["strategy"], "hold")
        self.assertIn("required_review_missing", result["blockers"])

    def test_incomplete_pagination_holds(self):
        result = classifier.classify(base(discovery_complete=False))
        self.assertEqual(result["strategy"], "hold")
        self.assertIn("discovery_incomplete", result["unknowns"])

    def test_dependency_cycle_holds(self):
        result = classifier.classify(base(dependency_cycle=True))
        self.assertEqual(result["strategy"], "hold")
        self.assertIn("dependency_cycle", result["blockers"])

    def test_sha_sensitive_independent_change_squashes(self):
        result = classifier.classify(base(commit_count=3, commit_sha_sensitive=True))
        self.assertEqual(result["strategy"], "squash")

    def test_unknown_independence_holds(self):
        result = classifier.classify(base(independent=False))
        self.assertEqual(result["strategy"], "hold")

    def test_analyze_summary_and_read_only(self):
        result = classifier.analyze({"change_requests": [base(), base(stacked=True)]})
        self.assertTrue(result["read_only"])
        self.assertEqual(result["summary"]["total"], 2)
        self.assertEqual(result["summary"]["squash"], 1)
        self.assertEqual(result["summary"]["merge_commit"], 1)

    def test_invalid_input_is_rejected(self):
        with self.assertRaises(ValueError):
            classifier.analyze({"change_requests": {}})


if __name__ == "__main__":
    unittest.main()
