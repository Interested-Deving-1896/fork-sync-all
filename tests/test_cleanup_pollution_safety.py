"""Safety regression tests for template-pollution cleanup."""

import os
import subprocess
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "cleanup-pollution.sh"


class CleanupPollutionSafetyTests(unittest.TestCase):
    def run_cleanup(self, dry_run):
        env = os.environ.copy()
        env.pop("SYNC_TOKEN", None)
        env["DRY_RUN"] = dry_run
        return subprocess.run(
            ["bash", str(SCRIPT)],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_live_cleanup_fails_closed_before_credentials_or_network(self):
        result = self.run_cleanup("false")
        self.assertEqual(result.returncode, 2)
        self.assertIn("live cleanup is disabled", result.stderr)
        self.assertNotIn("SYNC_TOKEN is required", result.stderr)

    def test_dry_run_remains_the_only_supported_mode(self):
        result = self.run_cleanup("true")
        self.assertNotEqual(result.returncode, 2)
        self.assertIn("SYNC_TOKEN is required", result.stderr)


if __name__ == "__main__":
    unittest.main()
