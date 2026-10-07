"""Tests for the forge-neutral README subsystem contract and cross-port engine."""

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "readme-subsystem.py"
CONFIG = ROOT / "config" / "readme-subsystem.json"


def load_module():
    spec = spec_from_file_location("readme_subsystem", SCRIPT)
    assert spec and spec.loader
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ReadmeSubsystemTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()
        self.data = self.module.load_config(CONFIG)

    def test_repository_contract_is_valid(self):
        self.assertEqual(self.module.validate_config(self.data, ROOT), [])

    def test_sync_is_directional_and_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            changed = self.module.sync_artifacts(
                self.data, ROOT, target, "interested-deving-1896", check=False
            )
            self.assertIn("scripts/readme_policy.py", changed)
            self.assertIn("scripts/check_rendered_links.py", changed)
            self.assertIn("scripts/readme-subsystem.py", changed)
            self.assertIn("config/readme-subsystem.json", changed)
            self.assertEqual(
                self.module.sync_artifacts(
                    self.data, ROOT, target, "interested-deving-1896", check=True
                ),
                [],
            )

    def test_sync_graph_has_no_reverse_edge(self):
        self.assertIsNone(self.data["projects"]["fork-sync-all"].get("sync_from"))
        self.assertEqual(
            self.data["projects"]["interested-deving-1896"]["sync_from"],
            "fork-sync-all",
        )


if __name__ == "__main__":
    unittest.main()
