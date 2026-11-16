"""Regression tests for README accessibility fallback rendering."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "update-readmes.sh"


class AccessibilityFallbackTests(unittest.TestCase):
    def test_fallback_does_not_execute_backtick_command_substitution(self):
        content = SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "No accessibility-report.json was found when this README was generated.",
            content,
        )
        self.assertNotIn(
            "No `accessibility-report.json` was found when this README was generated.",
            content,
        )


if __name__ == "__main__":
    unittest.main()
