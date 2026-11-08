import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "import-repo.sh"


class ImportRepoSafetyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SCRIPT.read_text(encoding="utf-8")

    def test_existing_destination_fails_closed(self):
        self.assertIn('if [ -n "$existing" ]; then', self.source)
        self.assertIn('error "Refusing to import into existing', self.source)
        self.assertNotIn("Already exists — will overwrite", self.source)

    def test_mirror_push_is_after_destination_guard(self):
        guard = self.source.index("Refusing to import into existing")
        mirror_push = self.source.index('git push --mirror "$gh_push_url"')
        self.assertLess(guard, mirror_push)

    def test_existing_repo_never_treated_as_empty_import_target(self):
        self.assertNotIn('Already exists — will overwrite via push.', self.source)


if __name__ == "__main__":
    unittest.main()
