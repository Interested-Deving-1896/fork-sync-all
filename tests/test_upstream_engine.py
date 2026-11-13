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
        self.assertFalse(record["candidate"])

    def test_requires_repository_or_organization(self):
        with self.assertRaisesRegex(ValueError, "--repo OWNER/NAME or --org"):
            upstream_engine.build_report()

    def test_rejects_non_qualified_repository_names(self):
        with self.assertRaisesRegex(ValueError, "OWNER/NAME"):
            upstream_engine.inspect_repository("not-a-repository")

    @patch("scripts.upstream_engine.request_json")
    def test_organization_discovery_paginates_and_requests_public_repos(self, request):
        first_page = [{"full_name": f"acme/repo-{i:03}", "archived": False} for i in range(100)]
        second_page = [{"full_name": "acme/z-last", "archived": False}]
        request.side_effect = [first_page, second_page]
        records = upstream_engine.list_organization_repositories("acme")
        self.assertEqual(len(records), 101)
        self.assertEqual(records[0]["full_name"], "acme/repo-000")
        self.assertIn("/orgs/acme/repos?", request.call_args_list[0].args[0])
        self.assertIn("type=public", request.call_args_list[0].args[0])
        self.assertIn("page=2", request.call_args_list[1].args[0])

    @patch("scripts.upstream_engine.list_organization_repositories")
    def test_org_report_is_deterministic_and_keeps_archived_for_reporting(self, discover):
        discover.return_value = [
            {
                "full_name": "linode/z-archived", "html_url": "https://github.com/linode/z-archived",
                "archived": True, "disabled": False, "fork": False, "pushed_at": None,
                "license": None, "description": "old docs", "topics": [], "language": "Python",
            },
            {
                "full_name": "linode/linodego", "html_url": "https://github.com/linode/linodego",
                "archived": False, "disabled": False, "fork": False, "pushed_at": None,
                "license": {"spdx_id": "MIT"}, "description": "Go client for Linode REST API",
                "topics": ["sdk"], "language": "Go",
            },
        ]
        report = upstream_engine.build_report(organizations=["linode"])
        self.assertEqual([x["repository"] for x in report["repositories"]],
                         ["linode/linodego", "linode/z-archived"])
        self.assertEqual(report["summary"]["repository_count"], 2)
        self.assertEqual(report["summary"]["candidate_count"], 1)
        self.assertEqual(report["summary"]["archived_count"], 1)
        self.assertEqual(report["repositories"][0]["category"], "sdk-cli")
        self.assertFalse(report["repositories"][1]["candidate"])
        self.assertFalse(report["mutations_performed"])

    @patch("scripts.upstream_engine.list_organization_repositories")
    def test_allow_deny_and_category_filters_apply_to_candidates(self, discover):
        discover.return_value = [
            {
                "full_name": "linode/linodego", "archived": False, "disabled": False,
                "fork": False, "pushed_at": None, "license": None, "description": "Go API client",
                "topics": ["sdk"], "language": "Go",
            },
            {
                "full_name": "linode/docs", "archived": False, "disabled": False,
                "fork": False, "pushed_at": None, "license": None, "description": "Guides and tutorials",
                "topics": [], "language": "Python",
            },
        ]
        report = upstream_engine.build_report(
            organizations=["linode"], allowlist=["linode/linodego", "linode/docs"],
            denylist=["linode/docs"], categories=["sdk-cli"],
        )
        self.assertEqual([x["repository"] for x in report["repositories"]], ["linode/linodego"])

    def test_rejects_invalid_organization_name(self):
        with self.assertRaisesRegex(ValueError, "invalid GitHub organization"):
            upstream_engine.list_organization_repositories("not/an/org")


if __name__ == "__main__":
    unittest.main()
