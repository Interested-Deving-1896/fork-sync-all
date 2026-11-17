"""CLI admission tests that must not contact a Git remote."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "mirror_chain_push.py"


class MirrorAdmissionTests(unittest.TestCase):
    def run_cli(self, overrides, *args):
        env = os.environ.copy()
        env.update(overrides)
        return subprocess.run(
            ["python3", str(SCRIPT), *args], cwd=ROOT, env=env,
            text=True, capture_output=True, check=False,
        )

    def test_wrong_repository_is_rejected_before_network(self):
        result = self.run_cli({"GITHUB_REPOSITORY": "attacker/fork"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("must run from OpenOS-Project-OSP/lkm", result.stderr)

    def test_write_is_rejected_outside_manual_dispatch(self):
        result = self.run_cli({
            "GITHUB_REPOSITORY": "OpenOS-Project-OSP/lkm",
            "GITHUB_EVENT_NAME": "pull_request",
            "MIRROR_WRITE_ENABLED": "true",
            "MIRROR_WRITE_APPROVED": "true",
            "MIRROR_TOKEN": "test-token",
        }, "--write")
        self.assertEqual(result.returncode, 1)
        self.assertIn("GITHUB_EVENT_NAME", result.stderr)


if __name__ == "__main__":
    unittest.main()
