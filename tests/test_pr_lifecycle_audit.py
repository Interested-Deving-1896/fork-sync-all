import unittest

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / ".github" / "scripts" / "pr-lifecycle-audit.py"
SPEC = spec_from_file_location("pr_lifecycle_audit", MODULE_PATH)
AUDIT = module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class CheckStateTests(unittest.TestCase):
    def test_no_checks_is_unknown(self):
        self.assertEqual(AUDIT.check_state([]), "unknown")

    def test_legacy_statuses_normalize_success_failure_and_pending(self):
        normalized = AUDIT.legacy_status_checks([
            {"context": "legacy-success", "state": "success"},
            {"context": "legacy-failure", "state": "failure"},
            {"context": "legacy-error", "state": "error"},
            {"context": "legacy-pending", "state": "pending"},
        ])
        self.assertEqual(AUDIT.check_state(normalized), "running")
        self.assertEqual(normalized[0]["conclusion"], "success")
        self.assertEqual(normalized[1]["conclusion"], "failure")
        self.assertEqual(normalized[2]["conclusion"], "failure")
        self.assertEqual(normalized[3]["status"], "in_progress")

    def test_legacy_failure_blocks_when_no_check_runs_exist(self):
        normalized = AUDIT.legacy_status_checks([
            {"context": "legacy-required-check", "state": "failure"},
        ])
        self.assertEqual(AUDIT.check_state(normalized), "failed")

    def test_in_progress_check_is_running(self):
        self.assertEqual(AUDIT.check_state([{"status": "in_progress"}]), "running")

    def test_failure_blocks(self):
        self.assertEqual(AUDIT.check_state([{"status": "completed", "conclusion": "failure"}]), "failed")

    def test_skipped_and_success_are_completed_not_failed(self):
        self.assertEqual(
            AUDIT.check_state([
                {"status": "completed", "conclusion": "success"},
                {"status": "completed", "conclusion": "skipped"},
            ]),
            "completed",
        )

    def test_draft_with_completed_checks_remains_draft(self):
        status, _ = AUDIT.classify({"draft": True, "mergeable": True}, [
            {"status": "completed", "conclusion": "success"}
        ])
        self.assertEqual(status, "DRAFT — REVIEW STATE NOT SET")


    def test_conflict_takes_priority_over_running_checks(self):
        status, _ = AUDIT.classify(
            {"draft": False, "mergeable": False},
            [{"status": "in_progress"}],
        )
        self.assertEqual(status, "BLOCKED")

    def test_behind_branch_is_stale(self):
        status, _ = AUDIT.classify(
            {"draft": False, "mergeable": True, "mergeable_state": "behind"},
            [{"status": "completed", "conclusion": "success"}],
        )
        self.assertEqual(status, "STALE")

    def test_completed_checks_are_not_called_merge_ready(self):
        status, _ = AUDIT.classify({"draft": False, "mergeable": True}, [
            {"status": "completed", "conclusion": "success"}
        ])
        self.assertEqual(status, "REVIEW REQUIRED")

    def test_conflict_blocks(self):
        status, _ = AUDIT.classify({"draft": False, "mergeable": False}, [
            {"status": "completed", "conclusion": "success"}
        ])
        self.assertEqual(status, "BLOCKED")


if __name__ == "__main__":
    unittest.main()
