import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("code_archaeology", ROOT / "scripts" / "code_archaeology.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


def git(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


class CodeArchaeologyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.name", "Fixture Author")
        git(self.repo, "config", "user.email", "fixture@example.invalid")
        (self.repo / "sample.txt").write_text("alpha\nbeta\ngamma\n", encoding="utf-8")
        git(self.repo, "add", "sample.txt")
        git(self.repo, "commit", "-qm", "initial fixture")

    def tearDown(self):
        self.tmp.cleanup()

    def test_read_only_commit_evidence(self):
        before = MODULE.git(self.repo, "rev-parse", "HEAD").strip()
        report = MODULE.investigate(str(self.repo), path="sample.txt")
        after = MODULE.git(self.repo, "rev-parse", "HEAD").strip()
        self.assertEqual(before, after)
        self.assertTrue(report["read_only"])
        self.assertFalse(report["execution_policy"]["repository_hooks_executed"])
        self.assertEqual(report["commits"][0]["subject"], "initial fixture")

    def test_ignores_git_environment_redirection(self):
        # A hostile caller environment must not redirect the read-only query.
        from unittest.mock import patch
        with patch.dict(os.environ, {"GIT_DIR": str(self.repo / "missing.git"),
                                     "GIT_CONFIG_COUNT": "1",
                                     "GIT_CONFIG_KEY_0": "core.hooksPath",
                                     "GIT_CONFIG_VALUE_0": "/tmp/unsafe-hooks"}):
            report = MODULE.investigate(str(self.repo), path="sample.txt")
        self.assertEqual(report["commits"][0]["subject"], "initial fixture")
        self.assertTrue(report["read_only"])

    def test_blame_porcelain_evidence(self):
        report = MODULE.investigate(str(self.repo), path="sample.txt", start=2, end=2)
        self.assertIn("beta", report["blame"]["porcelain"])
        self.assertIn("fixture@example.invalid", report["blame"]["porcelain"])

    def test_pickaxe_finds_introduction(self):
        report = MODULE.investigate(str(self.repo), path="sample.txt", pickaxe="beta")
        self.assertEqual(len(report["pickaxe_matches"]), 1)
        self.assertEqual(report["pickaxe_matches"][0]["subject"], "initial fixture")

    def test_rejects_parent_traversal(self):
        with self.assertRaisesRegex(ValueError, "repository-relative"):
            MODULE.investigate(str(self.repo), path="../outside.txt")

    def test_rejects_invalid_line_range_and_unbounded_limit(self):
        with self.assertRaisesRegex(ValueError, "line range"):
            MODULE.investigate(str(self.repo), path="sample.txt", start=3, end=2)
        with self.assertRaisesRegex(ValueError, "between 1"):
            MODULE.investigate(str(self.repo), limit=MODULE.MAX_LIMIT + 1)

    def test_markdown_discloses_limitations(self):
        rendered = MODULE.render_markdown(MODULE.investigate(str(self.repo)))
        self.assertIn("Recent commits", rendered)
        self.assertIn("not verified identities", rendered)


if __name__ == "__main__":
    unittest.main()
