import unittest
from pathlib import Path
import importlib.util
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "origins_audit_repair_engine.py"
spec = importlib.util.spec_from_file_location("origin_engine", SCRIPT)
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)


class NormalizeTests(unittest.TestCase):
    def test_valid_provenance_row(self):
        row = {"source": "owner/project", "url": "https://github.com/owner/project",
                "relationship": "reference", "what": "Used as reference"}
        result = engine.normalize(row)
        self.assertEqual(result["source"], "owner/project")
        self.assertEqual(result["registry_issues"], [])

    def test_invalid_relationship_reported(self):
        result = engine.normalize({"source": "bad", "url": "http://example.com",
                                  "relationship": "unknown"})
        self.assertIn("invalid-or-missing-source", result["registry_issues"])
        self.assertIn("unsupported-or-noncanonical-url", result["registry_issues"])
        self.assertIn("invalid-or-missing-relationship", result["registry_issues"])

    def test_non_mapping_row_reported_not_crashed(self):
        self.assertIn("invalid-row-type", engine.normalize("unexpected")["registry_issues"])

    def test_rejects_userinfo_and_host_suffix(self):
        self.assertFalse(engine.canonical_repo_url("https://github.com.evil.test/a/b"))
        self.assertFalse(engine.canonical_repo_url("https://user@github.com/a/b"))

    def test_redirect_is_not_followed(self):
        with patch.object(engine.urllib.request, "build_opener") as build:
            opener = build.return_value
            opener.open.side_effect = engine.urllib.error.HTTPError(
                "https://github.com/owner/repo", 302, "Found", {}, None)
            result = engine.check_url("https://github.com/owner/repo")
        self.assertEqual(result["status"], "redirect-not-followed")
        opener.open.assert_called_once()

    def test_registry_only_does_not_network(self):
        report = engine.audit([{"source": "owner/project",
                               "url": "https://github.com/owner/project",
                               "relationship": "fork"}])
        self.assertEqual(report["origins"][0]["remote"]["status"], "not-checked")
        self.assertEqual(report["origin_count"], 1)


if __name__ == "__main__":
    unittest.main()
