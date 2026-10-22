"""Offline security regression tests for GitLab mirror destinations."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "sync-upstream-mirrors.sh"


class MirrorDestinationValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.fixture = self.root / "projects.json"
        self.git_log = self.root / "git.log"

        curl = self.bin / "curl"
        curl.write_text(
            "#!/bin/bash\n"
            "set -eu\n"
            "out=''\n"
            "while (($#)); do\n"
            "  case \"$1\" in\n"
            "    --output) out=\"$2\"; shift 2 ;;\n"
            "    --write-out) shift 2 ;;\n"
            "    --header) shift 2 ;;\n"
            "    *) url=\"$1\"; shift ;;\n"
            "  esac\n"
            "done\n"
            "cp \"$FIXTURE_JSON\" \"$out\"\n"
            "printf 200\n",
            encoding="utf-8",
        )
        curl.chmod(0o755)

        git = self.bin / "git"
        git.write_text(
            "#!/bin/bash\n"
            "printf '%s\\n' \"$*\" >> \"$GIT_LOG\"\n"
            "exit 0\n",
            encoding="utf-8",
        )
        git.chmod(0o755)

    def run_project(self, destination, source="https://github.com/example/fixture-project.git"):
        self.fixture.write_text(
            json.dumps([{
                "id": 1,
                "name": "fixture-project",
                "http_url_to_repo": destination,
                "import_url": source,
            }]),
            encoding="utf-8",
        )
        env = os.environ.copy()
        env.update({
            "PATH": f"{self.bin}:{env.get('PATH', '')}",
            "GITLAB_TOKEN": "fixture-token",
            "FIXTURE_JSON": str(self.fixture),
            "GIT_LOG": str(self.git_log),
        })
        return subprocess.run(
            ["bash", str(SCRIPT)],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_rejects_https_destination_on_untrusted_host_before_git(self):
        result = self.run_project(
            "https://gitlab.com.attacker.invalid/openos-project/upstream-mirrors/project.git"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid http_url_to_repo destination", result.stderr)
        self.assertFalse(self.git_log.exists(), "invalid destination must not invoke git")

    def test_rejects_gitlab_url_with_userinfo_before_git(self):
        result = self.run_project(
            "https://attacker@ gitlab.com/openos-project/upstream-mirrors/project.git".replace(" ", "")
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid http_url_to_repo destination", result.stderr)
        self.assertFalse(self.git_log.exists(), "userinfo destination must not invoke git")

    def test_valid_gitlab_destination_is_used_by_mocked_git(self):
        result = self.run_project(
            "https://gitlab.com/openos-project/upstream-mirrors/fixture-project.git"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.git_log.exists())
        self.assertIn("oauth2:fixture-token@gitlab.com/openos-project/upstream-mirrors/fixture-project.git",
                      self.git_log.read_text(encoding="utf-8"))



    def test_rejects_noncanonical_github_sources_before_clone(self):
        invalid_sources = [
            "http://github.com/example/project.git",
            "https://github.com.attacker.invalid/example/project.git",
            "https://github.com:8443/example/project.git",
            "https://github.com/example/project.git?download=1",
            "https://github.com/example/project.git#fragment",
            "https://user@github.com/example/project.git",
            "https://github.com/",
            "https://github.com/example/../project.git",
            "https://github.com\\\\example\\\\project.git",
            "https://github.com/example/project.git\\n",
        ]
        invalid_sources.extend([
            "https://github.com/example/%0aproject.git",
            "https://github.com/example/pro%7fject.git",
        ])
        destination = "https://gitlab.com/openos-project/upstream-mirrors/fixture-project.git"
        for source in invalid_sources:
            with self.subTest(source=repr(source)):
                if self.git_log.exists():
                    self.git_log.unlink()
                result = self.run_project(destination, source=source)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(self.git_log.exists(), f"rejected import URL reached git: {source!r}")

    def test_accepts_canonical_github_https_clone_url(self):
        destination = "https://gitlab.com/openos-project/upstream-mirrors/fixture-project.git"
        result = self.run_project(destination, source="https://github.com/example/project.git")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.git_log.exists())
        self.assertIn("clone --mirror https://github.com/example/project.git", self.git_log.read_text(encoding="utf-8"))

    def test_accepts_explicit_default_https_port(self):
        destination = "https://gitlab.com/openos-project/upstream-mirrors/fixture-project.git"
        result = self.run_project(destination, source="https://github.com:443/example/project.git")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.git_log.exists())

if __name__ == "__main__":
    unittest.main()
