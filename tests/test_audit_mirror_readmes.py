"""Unit tests for mirror-chain README baseline checks."""

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import json
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "audit-mirror-readmes.py"
POLICY = ROOT / "config" / "mirror-readme-baseline.json"


def load_module():
    spec = spec_from_file_location("audit_mirror_readmes", SCRIPT)
    assert spec and spec.loader
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class AuditMirrorReadmesTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()
        self.policy = json.loads(POLICY.read_text(encoding="utf-8"))

    def test_complete_managed_readme_passes(self):
        sections = []
        for section in self.policy["required_managed_sections"]:
            sections.append(
                f"<!-- AI:start:{section} -->\ncontent\n<!-- AI:end:{section} -->"
            )
        headings = "\n".join(f"## {value}" for value in self.policy["required_headings"])
        content = f"# Demo\n\n[![Built with Ona](badge)]\n\n{headings}\n" + "\n".join(sections)
        self.assertEqual(self.module.baseline_findings(content, self.policy), [])

    def test_missing_accessibility_heading_is_reported(self):
        findings = self.module.baseline_findings("# Demo\n", self.policy)
        self.assertIn("missing heading: Accessibility", findings)

    def test_missing_readme_is_reported(self):
        self.assertEqual(
            self.module.baseline_findings(None, self.policy), ["README.md is missing"]
        )


if __name__ == "__main__":
    unittest.main()
