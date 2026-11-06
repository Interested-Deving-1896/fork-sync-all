"""Unit tests for the report-only Upstream Engine prototype."""
import unittest
from unittest.mock import patch

from scripts import upstream_engine


class UpstreamEngineTests(unittest.TestCase):
    @patch("scripts.upstream_engine.request_json")
    def test_fork_lineage_and_staleness_are_reported(self, request):
        request.return_value = {
            "full_name": "acme/old-project", "html_url": "https://github.com/acme/old-project",
            "archived": False, "disabled": False, "fork": True,
            "parent": {"full_name": "upstream/project"},
            "source": {"full_name": "upstream/project"},
            "default_branch": "main", "created_at": "2020-01-01T00:00:00Z",
            "pushed_at": "2020-01-01T00:00:00Z",
            "license": {"spdx_id": "MIT"},
        }
        record = upstream_engine.inspect_repository("acme/old-project")
        self.assertEqual(record["lineage"]["canonical_source"], "upstream/project")
        self.assertEqual(record["assessment"], "stale_candidate")
        self.assertEqual(record["license"], "MIT")

    @patch("scripts.upstream_engine.request_json")
    def test_archived_repository_without_lineage_is_not_guessed(self, request):
        request.return_value = {
            "full_name": "acme/abandoned", "archived": True, "disabled": False,
            "fork": False, "pushed_at": None, "license": None,
        }
        record = upstream_engine.inspect_repository("acme/abandoned")
        self.assertEqual(record["assessment"], "archived_review_required")
        self.assertIsNone(record["lineage"]["canonical_source"])

    def test_requires_explicit_allowlist(self):
        with self.assertRaisesRegex(ValueError, "explicitly admitted"):
            upstream_engine.build_report([])

    def test_rejects_non_qualified_repository_names(self):
        with self.assertRaisesRegex(ValueError, "OWNER/NAME"):
            upstream_engine.inspect_repository("not-a-repository")


if __name__ == "__main__":
    unittest.main()
