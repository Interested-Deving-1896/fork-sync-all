import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / ".github" / "scripts"))
from gitlab_mr_lifecycle_adapter import (
    classify_merge_request,
    normalize_merge_request,
    normalize_pipeline,
)


class GitLabLifecycleAdapterTests(unittest.TestCase):
    def test_success_pipeline_is_review_required_not_merge_ready(self):
        self.assertEqual(classify_merge_request(
            {"iid": 12, "draft": False, "detailed_merge_status": "mergeable"},
            [{"id": 4, "status": "success"}],
        )[0], "REVIEW REQUIRED")

    def test_running_pipeline_wins(self):
        self.assertEqual(classify_merge_request(
            {"iid": 12, "detailed_merge_status": "mergeable"},
            [{"status": "running"}],
        )[0], "RUNNING")

    def test_failed_pipeline_blocks(self):
        self.assertEqual(classify_merge_request(
            {"iid": 12, "detailed_merge_status": "mergeable"},
            [{"status": "failed"}],
        )[0], "BLOCKED")

    def test_cancelled_pipeline_requires_investigation(self):
        self.assertEqual(classify_merge_request(
            {"iid": 12, "detailed_merge_status": "mergeable"},
            [{"status": "canceled"}],
        )[0], "INVESTIGATE")

    def test_manual_pipeline_requires_action(self):
        self.assertEqual(classify_merge_request(
            {"iid": 12, "detailed_merge_status": "mergeable"},
            [{"status": "manual"}],
        )[0], "BLOCKED")

    def test_conflict_overrides_success(self):
        self.assertEqual(classify_merge_request(
            {"iid": 12, "has_conflicts": True, "detailed_merge_status": "mergeable"},
            [{"status": "success"}],
        )[0], "BLOCKED")

    def test_unknown_merge_status_fails_closed(self):
        normalized = normalize_merge_request(
            {"iid": 12, "detailed_merge_status": "new_future_status"}, []
        )
        self.assertEqual(normalized["merge_state"], "unstable")
        self.assertEqual(classify_merge_request(
            {"iid": 12, "detailed_merge_status": "new_future_status"},
            [{"status": "success"}],
        )[0], "BLOCKED")

    def test_draft_is_preserved(self):
        normalized = normalize_merge_request(
            {"iid": 12, "work_in_progress": True, "detailed_merge_status": "mergeable"},
            [{"status": "success"}],
        )
        self.assertTrue(normalized["draft"])
        self.assertEqual(classify_merge_request(
            {"iid": 12, "work_in_progress": True, "detailed_merge_status": "mergeable"},
            [{"status": "success"}],
        )[0], "DRAFT — REVIEW STATE NOT SET")

    def test_pipeline_evidence_preserves_url_and_sha(self):
        normalized = normalize_pipeline({
            "id": 9, "status": "success", "web_url": "https://gitlab.example/pipelines/9",
            "sha": "abc123",
        })
        self.assertEqual(normalized["web_url"], "https://gitlab.example/pipelines/9")
        self.assertEqual(normalized["sha"], "abc123")


if __name__ == "__main__":
    unittest.main()
