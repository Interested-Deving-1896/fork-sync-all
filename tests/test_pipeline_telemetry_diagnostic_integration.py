"""Regression guards for the telemetry adapter integration boundary."""
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "pipeline-telemetry.sh"


class PipelineTelemetryIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SCRIPT.read_text(encoding="utf-8")

    def test_uses_exact_attempt_adapter_and_sha(self):
        self.assertIn("github_actions_log_adapter.py", self.source)
        self.assertIn("--expected-head-sha", self.source)
        self.assertIn("/attempts/${RUN_ATTEMPT}", self.source)
        self.assertNotIn("|| gh_get", self.source)

    def test_never_follows_authenticated_logs_redirect_in_shell(self):
        self.assertNotIn("curl -sf -L", self.source)
        self.assertNotIn("LOGS_ZIP", self.source)
        self.assertIn("LOGS_STATUS", self.source)

    def test_raw_logs_are_private_ephemeral_and_redacted_before_summary(self):
        self.assertIn("umask 077", self.source)
        self.assertIn("mktemp -d", self.source)
        self.assertIn("trap cleanup_telemetry EXIT", self.source)
        self.assertIn("body = redact_text(", self.source)
        self.assertIn("log_summary", self.source)


if __name__ == "__main__":
    unittest.main()
