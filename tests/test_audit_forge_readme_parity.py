"""Tests for forge-neutral README parity comparisons."""

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "audit-forge-readme-parity.py"


def load_module():
    spec = spec_from_file_location("audit_forge_readme_parity", SCRIPT)
    assert spec and spec.loader
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def surface(identifier, platform, projects):
    return {
        "id": identifier,
        "platform": platform,
        "namespace": identifier,
        "projects": projects,
    }


def project(coordinate, digest="same", present=True):
    return [{"coordinate": coordinate, "readme": present, "sha256": digest, "content": ""}]


class ForgeParityTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()

    def test_equal_readmes_across_platforms_are_healthy(self):
        report = self.module.compare_snapshots(
            [
                surface("source", "github", {"demo": project("source/demo")}),
                surface("gitlab", "gitlab", {"demo": project("group/tools/demo")}),
                surface("codeberg", "codeberg", {"demo": project("group/demo")}),
            ],
            "source",
            set(),
        )
        self.assertTrue(report["healthy"])
        self.assertEqual(report["findings"], [])

    def test_drift_and_missing_readme_are_reported(self):
        report = self.module.compare_snapshots(
            [
                surface(
                    "source",
                    "github",
                    {"drift": project("source/drift"), "missing": project("source/missing")},
                ),
                surface(
                    "forgejo",
                    "forgejo",
                    {
                        "drift": project("group/drift", digest="different"),
                        "missing": project("group/missing", present=False, digest=None),
                    },
                ),
            ],
            "source",
            set(),
        )
        self.assertFalse(report["healthy"])
        findings = {item["finding"] for item in report["findings"]}
        self.assertIn("README content differs from canonical source", findings)
        self.assertIn("downstream README.md is missing", findings)

    def test_exceptions_and_unobserved_source_projects_are_not_findings(self):
        report = self.module.compare_snapshots(
            [
                surface(
                    "source",
                    "github",
                    {"source-only": project("source/source-only")},
                ),
                surface("gitlab", "gitlab", {"native": project("group/native")}),
            ],
            "source",
            {"native"},
        )
        self.assertTrue(report["healthy"])

    def test_duplicate_nested_project_names_are_ambiguous(self):
        report = self.module.compare_snapshots(
            [surface("source", "github", {"demo": project("source/demo")}),
             surface("gitlab", "gitlab", {
                 "demo": project("group/a/demo") + project("group/b/demo")
             })],
            "source",
            set(),
        )
        self.assertFalse(report["healthy"])
        self.assertEqual(
            report["findings"][0]["finding"],
            "ambiguous project name across nested namespaces",
        )


if __name__ == "__main__":
    unittest.main()
