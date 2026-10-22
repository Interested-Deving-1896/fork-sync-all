"""Regression tests for the upstream-mirror workflow's safety inputs."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "sync-upstream-mirrors.sh"


class UpstreamMirrorDryRunTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.fixture = self.root / "projects.json"
        self.git_log = self.root / "git.log"
        self.fixture.write_text(
            json.dumps([
                {
                    "id": 1,
                    "name": "project-alpha",
                    "http_url_to_repo": "https://gitlab.com/openos-project/upstream-mirrors/project-alpha.git",
                    "import_url": "https://github.com/example/project-alpha.git",
                },
                {
                    "id": 2,
                    "name": "project-beta",
                    "http_url_to_repo": "https://gitlab.com/openos-project/upstream-mirrors/project-beta.git",
                    "import_url": "https://github.com/example/project-beta.git",
                },
            ]),
            encoding="utf-8",
        )
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
            "case \"$url\" in *page=1*) ;; *) echo 'unexpected page' >&2; exit 9 ;; esac\n"
            "if [[ \\"${CURL_MODE:-}\\" == transport ]]; then exit 22; fi\\n"
            "cp \"$FIXTURE_JSON\" \"$out\"\n"
            "printf 200\n",
            encoding="utf-8",
        )
        curl.chmod(0o755)
        git = self.bin / "git"
        git.write_text(
            "#!/bin/bash\n"
            "printf '%s\\n' \"$*\" >> \"$GIT_LOG\"\n",
            encoding="utf-8",
        )
        git.chmod(0o755)

    def run_script(self, **overrides):
        env = os.environ.copy()
        env.update({
            "PATH": f"{self.bin}:{env.get('PATH', '')}",
            "GITLAB_TOKEN": "test-token",
            "FIXTURE_JSON": str(self.fixture),
            "GIT_LOG": str(self.git_log),
            "DRY_RUN": "true",
            "REPO_FILTER": "",
        })
        env.update(overrides)
        return subprocess.run(
            ["bash", str(SCRIPT)],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_dry_run_never_invokes_git(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DRY RUN — would sync: project-alpha", result.stderr)
        self.assertIn("DRY RUN — would sync: project-beta", result.stderr)
        self.assertIn("would sync: 2", result.stderr)
        self.assertFalse(self.git_log.exists(), "dry-run must not clone or push")

    def test_repository_filter_is_applied_before_sync(self):
        result = self.run_script(REPO_FILTER="alpha")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DRY RUN — would sync: project-alpha", result.stderr)
        self.assertIn("SKIP (does not match repo filter): project-beta", result.stderr)
        self.assertIn("would sync: 1", result.stderr)
        self.assertFalse(self.git_log.exists(), "filtered dry-run must not invoke git")

    def test_transport_failure_fails_closed_before_git(self):
        result = self.run_script(CURL_MODE="transport")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("transport failed on page 1", result.stderr)
        self.assertFalse(self.git_log.exists(), "transport failure must not invoke git")

    def test_malformed_json_fails_closed_before_git(self):
        self.fixture.write_text("{not-json", encoding="utf-8")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid GitLab projects response", result.stderr)
        self.assertFalse(self.git_log.exists(), "invalid JSON must not invoke git")

    def test_invalid_project_record_fails_closed_before_git(self):
        self.fixture.write_text(
            json.dumps([{"id": "not-an-integer", "name": "bad",
                         "http_url_to_repo": "https://gitlab.com/example/bad.git",
                         "import_url": "https://github.com/example/bad.git"}]),
            encoding="utf-8",
        )
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing/invalid id", result.stderr)
        self.assertFalse(self.git_log.exists(), "invalid records must not invoke git")

    def test_invalid_dry_run_value_fails_closed(self):
        result = self.run_script(DRY_RUN="yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DRY_RUN must be exactly", result.stderr)
        self.assertFalse(self.git_log.exists())


if __name__ == "__main__":
    unittest.main()
