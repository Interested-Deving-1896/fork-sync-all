import unittest

from pr_lifecycle_core import check_state, classify_lifecycle


class ProviderNeutralLifecycleTests(unittest.TestCase):
    def test_empty_evidence_is_unknown(self):
        self.assertEqual(check_state([]), "unknown")

    def test_active_check_wins_over_completed_failure(self):
        self.assertEqual(check_state([
            {"status": "completed", "conclusion": "failure"},
            {"status": "queued", "conclusion": None},
        ]), "running")

    def test_failure_is_blocked(self):
        self.assertEqual(classify_lifecycle(
            checks=[{"status": "completed", "conclusion": "failure"}],
        )[0], "BLOCKED")

    def test_cancelled_is_investigate_not_success(self):
        self.assertEqual(classify_lifecycle(
            checks=[{"status": "completed", "conclusion": "cancelled"}],
        )[0], "INVESTIGATE")

    def test_skipped_and_success_complete(self):
        self.assertEqual(check_state([
            {"status": "completed", "conclusion": "success"},
            {"status": "completed", "conclusion": "skipped"},
        ]), "completed")

    def test_conflict_overrides_running(self):
        self.assertEqual(classify_lifecycle(
            checks=[{"status": "in_progress"}], mergeable=False,
        )[0], "BLOCKED")

    def test_behind_is_stale(self):
        self.assertEqual(classify_lifecycle(
            checks=[{"status": "completed", "conclusion": "success"}],
            merge_state="behind",
        )[0], "STALE")

    def test_draft_is_never_promoted_by_checks(self):
        self.assertEqual(classify_lifecycle(
            checks=[{"status": "completed", "conclusion": "success"}], draft=True,
        )[0], "DRAFT — REVIEW STATE NOT SET")

    def test_success_is_review_required_not_merge_ready(self):
        self.assertEqual(classify_lifecycle(
            checks=[{"status": "completed", "conclusion": "success"}],
        )[0], "REVIEW REQUIRED")


if __name__ == "__main__":
    unittest.main()
