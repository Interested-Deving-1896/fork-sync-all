from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "readme-marker-audit.py"
SPEC = importlib.util.spec_from_file_location("readme_marker_audit", SCRIPT)
AUDIT = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(AUDIT)


class ReadmeMarkerAuditTests(unittest.TestCase):
    def test_balanced_ai_and_human_regions(self):
        text = """<!-- HUMAN:start -->
<!-- AI:start:architecture -->
managed
<!-- AI:end:architecture -->
<!-- HUMAN:end -->"""
        self.assertEqual([], AUDIT.audit(text))

    def test_nested_lts_and_ai_regions(self):
        text = """<!-- LTS:start:overview -->
<!-- AI:start:ci -->
ci
<!-- AI:end:ci -->
<!-- LTS:end:overview -->"""
        self.assertEqual([], AUDIT.audit(text))

    def test_unmatched_end(self):
        self.assertTrue(any("unmatched" in e for e in AUDIT.audit("<!-- AI:end:ci -->")))

    def test_unclosed_start(self):
        self.assertTrue(any("unclosed" in e for e in AUDIT.audit("<!-- AI:start:ci -->")))

    def test_mismatched_pair(self):
        text = "<!-- AI:start:ci -->\n<!-- AI:end:architecture -->"
        self.assertTrue(any("does not match" in e for e in AUDIT.audit(text)))

    def test_duplicate_section(self):
        text = """<!-- AI:start:ci -->
<!-- AI:end:ci -->
<!-- AI:start:ci -->
<!-- AI:end:ci -->"""
        self.assertTrue(any("duplicate" in e for e in AUDIT.audit(text)))

    def test_malformed_marker_is_rejected(self):
        self.assertTrue(any("malformed" in e for e in AUDIT.audit("<!-- AI:start: -->")))

    def test_audit_does_not_mutate_input(self):
        text = "<!-- AI:start:ci -->\noriginal\n<!-- AI:end:ci -->"
        before = text
        AUDIT.audit(text)
        self.assertEqual(before, text)


if __name__ == "__main__":
    unittest.main()
