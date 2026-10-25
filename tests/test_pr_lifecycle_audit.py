import unittest
from unittest import mock

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / ".github" / "scripts" / "pr-lifecycle-audit.py"
SPEC = spec_from_file_location("pr_lifecycle_audit", MODULE_PATH)
AUDIT = module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class CheckStateTests(unittest.TestCase):
    def test_no_checks_is_unknown(self):
        self.assertEqual(AUDIT.check_state([]), "unknown")

    def test_pagination_accepts_bare_list_response(self):
        with mock.patch.object(AUDIT, "api_get", return_value=[{"id": 1}]):
            self.assertEqual(AUDIT.paginated("/test", "items"), [{"id": 1}])

    def test_pagination_fails_closed_on_malformed_payload(self):
        for payload in ({"message": "unexpected"}, {"check_runs": {"wrong": "shape"}}, None):
            with self.subTest(payload=payload):
                with mock.patch.object(AUDIT, "api_get", return_value=payload):
                    with self.assertRaises(AUDIT.ApiError):
                        AUDIT.paginated("/test", "check_runs")

    def test_pagination_follows_full_page(self):
        first = [{"id": n} for n in range(100)]
        second = [{"id": 100}]
        with mock.patch.object(AUDIT, "api_get", side_effect=[first, second]) as api_get:
            result = AUDIT.paginated("/test", "items")
        self.assertEqual(len(result), 101)
        self.assertEqual(result[-1], {"id": 100})
        self.assertEqual(api_get.call_count, 2)

    def test_legacy_statuses_normalize_and_latest_context_wins(self):
        normalized = AUDIT.legacy_status_checks([
            {"context": "build", "state": "failure", "created_at": "2026-10-20T11:00:00Z"},
            {"context": "build", "state": "success", "created_at": "2026-10-20T12:00:00Z"},
            {"context": "lint", "state": "pending", "created_at": "2026-10-20T12:00:00Z"},
        ])
        self.assertEqual(len(normalized), 2)
        self.assertEqual(AUDIT.check_state(normalized), "running")
        build = next(item for item in normalized if item["name"] == "build")
        self.assertEqual(build["conclusion"], "success")

    def test_api_get_normalizes_invalid_utf8_to_api_error(self):
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = b"\\xff\\xfe"
        with mock.patch.object(AUDIT.urllib.request, "urlopen", return_value=response):
            with self.assertRaises(AUDIT.ApiError):
                AUDIT.api_get("/test")

    def test_legacy_status_ties_are_deterministic_across_response_order(self):
        first = {"context": "build", "state": "failure", "created_at": "2026-10-20T12:00:00Z"}
        second = {"context": "build", "state": "success", "created_at": "2026-10-20T12:00:00Z"}
        forward = AUDIT.legacy_status_checks([first, second])
        reverse = AUDIT.legacy_status_checks([second, first])
        self.assertEqual(forward, reverse)

    def test_legacy_status_missing_timestamps_are_deterministic(self):
        first = {"context": "build", "state": "failure"}
        second = {"context": "build", "state": "success"}
        forward = AUDIT.legacy_status_checks([first, second])
        reverse = AUDIT.legacy_status_checks([second, first])
        self.assertEqual(forward, reverse)

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
