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

    def test_branch_tag_push_is_after_destination_guard(self):
        guard = self.source.index("Refusing to import into existing")
        branch_tag_push = self.source.index("git push --prune")
        self.assertLess(guard, branch_tag_push)

    def test_initial_push_excludes_github_managed_pull_request_refs(self):
        self.assertIn("git push", self.source)
        self.assertNotIn("git push --prune", self.source)
        self.assertNotIn("'+refs/heads/*:refs/heads/*'", self.source)
        self.assertNotIn("'+refs/tags/*:refs/tags/*'", self.source)
        self.assertIn("'+refs/heads/*:refs/heads/*'", self.source)
        self.assertIn("'+refs/tags/*:refs/tags/*'", self.source)
        self.assertNotIn('git push --mirror "$gh_push_url"', self.source)

    def test_push_result_uses_exit_status_not_grep_q_pipeline(self):
        self.assertIn("push_status=$?", self.source)
        self.assertIn('if [ "$push_status" -eq 0 ]; then', self.source)
        self.assertNotIn('if ! echo "$push_out" | grep -q "remote rejected"; then', self.source)

    def test_source_default_branch_is_preserved(self):
        self.assertIn("git symbolic-ref --quiet --short HEAD", self.source)
        self.assertIn('"default_branch": os.environ["SOURCE_DEFAULT_BRANCH"]', self.source)
        self.assertIn("Could not resolve the source repository's symbolic default branch", self.source)

    def test_osp_push_excludes_github_managed_refs(self):
        self.assertIn("git -C \"$work_dir/repo.git\" push --prune", self.source)
        self.assertNotIn('git -C "$work_dir/repo.git" push --mirror "$osp_push_url"', self.source)

    def test_existing_repo_never_treated_as_empty_import_target(self):
        self.assertNotIn('Already exists — will overwrite via push.', self.source)


if __name__ == "__main__":
    unittest.main()
