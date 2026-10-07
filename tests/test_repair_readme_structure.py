"""Tests for deterministic managed README heading repair."""

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "repair-readme-structure.py"


def load_module():
    spec = spec_from_file_location("repair_readme_structure", SCRIPT)
    assert spec and spec.loader
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RepairReadmeStructureTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()

    def test_adds_missing_heading_without_changing_block(self):
        content = "# Demo\n\n<!-- AI:start:accessibility -->\nBody\n<!-- AI:end:accessibility -->\n"
        updated = self.module.repair(content)
        self.assertIn("## Accessibility\n\n<!-- AI:start:accessibility -->", updated)
        self.assertIn("\nBody\n<!-- AI:end:accessibility -->", updated)

    def test_existing_heading_is_idempotent(self):
        content = "# Demo\n\n## Accessibility\n\n<!-- AI:start:accessibility -->\nBody\n<!-- AI:end:accessibility -->\n"
        self.assertEqual(self.module.repair(content), content)

    def test_does_not_create_sections_without_managed_blocks(self):
        content = "# Upstream project\n\nHuman-authored content.\n"
        self.assertEqual(self.module.repair(content), content)

    def test_replaces_stale_generated_accessibility_reference(self):
        content = (
            "# Demo\n\n## Accessibility\n\n"
            "<!-- AI:start:accessibility -->\n"
            "See [DOCS/accessibility.md](https://github.com/example/demo/blob/main/"
            "DOCS/accessibility.md) for the full accessibility reference.\n"
            "<!-- AI:end:accessibility -->\n"
        )

        updated = self.module.repair(content)

        self.assertNotIn("DOCS/accessibility.md", updated)
        self.assertIn("https://www.w3.org/WAI/standards-guidelines/wcag/", updated)
        self.assertEqual(self.module.repair(updated), updated)

    def test_removes_hallucinated_attribution_and_repairs_bot_profile(self):
        content = (
            "# Demo\n\n## Contributors\n\n<!-- AI:start:contributors -->\n"
            "- [Interested-Deving-1896](https://github.com/Interested-Deving-1896)\n"
            "- [TechGuru42](https://github.com/TechGuru42) - 15 commits\n"
            "- [@dependabot[bot]](https://github.com/dependabot[bot]): 1 commit\n"
            "*Mirror: [upstream](https://github.com/original-author/demo).*\n"
            "<!-- AI:end:contributors -->\n"
        )

        updated = self.module.repair(content)

        self.assertNotIn("TechGuru42", updated)
        self.assertNotIn("original-author", updated)
        self.assertIn("https://github.com/apps/dependabot", updated)


if __name__ == "__main__":
    unittest.main()
