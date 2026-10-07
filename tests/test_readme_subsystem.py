"""Tests for the forge-neutral README subsystem contract and cross-port engine."""

from importlib.util import module_from_spec, spec_from_file_location
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "readme-subsystem.py"
CONFIG = ROOT / "config" / "readme-subsystem.json"
LOCK = ROOT / "config" / "readme-subsystem.lock.json"
FIXTURES = ROOT / "tests" / "fixtures" / "readme-subsystem"


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

    def test_multi_forge_fixtures_are_valid(self):
        fixtures = sorted(FIXTURES.glob("*.json"))
        self.assertEqual(len(fixtures), 5)
        for fixture in fixtures:
            with self.subTest(fixture=fixture.name):
                data = self.module.load_config(fixture)
                self.assertEqual(self.module.validate_config(data, ROOT), [])

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
            self.assertIn("config/readme-subsystem.lock.json", changed)
            self.assertIn("schema/readme-subsystem.schema.json", changed)
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

    def test_provenance_lock_matches_canonical_artifacts(self):
        expected = self.module.build_lock(self.data, ROOT)
        actual = json.loads(LOCK.read_text(encoding="utf-8"))
        self.assertEqual(actual, expected)

    def test_upstream_proposal_is_patch_only(self):
        with tempfile.TemporaryDirectory() as profile_directory, tempfile.TemporaryDirectory() as output_directory:
            profile = Path(profile_directory)
            self.module.sync_artifacts(
                self.data, ROOT, profile, "interested-deving-1896", check=False
            )
            candidate = profile / "scripts" / "readme_policy.py"
            candidate.write_text(
                candidate.read_text(encoding="utf-8") + "\n# proposal fixture\n",
                encoding="utf-8",
            )
            count = self.module.propose_upstream(
                self.data,
                ROOT,
                profile,
                "interested-deving-1896",
                Path(output_directory),
            )
            self.assertEqual(count, 1)
            proposal = json.loads(
                (Path(output_directory) / "proposal.json").read_text(encoding="utf-8")
            )
            self.assertFalse(proposal["automatic_reverse_sync"])
            patch = (Path(output_directory) / "readme-subsystem-upstream.patch").read_text(
                encoding="utf-8"
            )
            self.assertIn("scripts/readme_policy.py", patch)
            self.assertIn("proposal fixture", patch)


if __name__ == "__main__":
    unittest.main()
