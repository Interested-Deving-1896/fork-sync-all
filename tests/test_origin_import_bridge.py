import unittest
from scripts.origin_import_bridge import audit, canonical_source_url


class OriginImportBridgeTests(unittest.TestCase):
    def test_normalizes_git_suffix_and_trailing_slash(self):
        self.assertEqual(canonical_source_url("https://Codeberg.org/Calamares/calamares.git/"),
                         "https://codeberg.org/Calamares/calamares")

    def test_supports_nested_gitlab_group_paths(self):
        self.assertEqual(canonical_source_url("https://gitlab.com/group/subgroup/project.git"),
                         "https://gitlab.com/group/subgroup/project")

    def test_rejects_credentials_and_non_https(self):
        self.assertIsNone(canonical_source_url("https://token@codeberg.org/a/b"))
        self.assertIsNone(canonical_source_url("http://codeberg.org/a/b"))

    def test_links_both_registries(self):
        report = audit(
            [{"source_url": "https://codeberg.org/Calamares/calamares.git", "target_name": "calamares-upstream"}],
            [{"source": "Calamares/calamares", "url": "https://codeberg.org/Calamares/calamares",
              "relationship": "fork"}])
        self.assertEqual(report["counts"]["linked"], 1)
        self.assertEqual(report["counts"]["import_without_origin"], 0)
        self.assertEqual(report["counts"]["origin_without_import"], 0)

    def test_import_without_origin_is_reported(self):
        report = audit([{"source_url": "https://codeberg.org/Calamares/calamares",
                         "target_name": "calamares-upstream"}], [])
        self.assertEqual(report["counts"]["import_without_origin"], 1)

    def test_origin_without_import_is_reported_not_imported(self):
        report = audit([], [{"source": "Calamares/calamares",
                             "url": "https://codeberg.org/Calamares/calamares",
                             "relationship": "reference"}])
        self.assertEqual(report["counts"]["origin_without_import"], 1)
        self.assertFalse(report["policy"]["repository_creation"])
        self.assertFalse(report["policy"]["workflow_dispatch"])

    def test_duplicate_source_urls_reported(self):
        row = {"source_url": "https://codeberg.org/Calamares/calamares", "target_name": "calamares-upstream"}
        report = audit([row, row], [])
        self.assertEqual(report["counts"]["duplicate_import_urls"], 1)


if __name__ == "__main__":
    unittest.main()
