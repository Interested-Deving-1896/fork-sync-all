import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("origins_archaeology", ROOT / "scripts" / "origins_archaeology.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class OriginsArchaeologyTests(unittest.TestCase):
    def test_origins_seed_preserves_declaration(self):
        source = """influences:
  - source: example/upstream
    url: https://github.com/example/upstream
    relationship: inspired-by
    what: Inspired the algorithm
    artifact: src/algorithm.py
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "provenance.yml"
            path.write_text(source, encoding="utf-8")
            result = MODULE.origins_to_investigations(path, "owner/project")
        self.assertEqual(result["direction"], "origins-to-archaeology")
        request = result["requests"][0]
        self.assertEqual(request["declared_source"], "example/upstream")
        self.assertEqual(request["relationship"], "inspired-by")
        self.assertEqual(request["artifact_paths"], ["src/algorithm.py"])
        self.assertEqual(request["mode"], "read-only")

    def test_archaeology_output_is_proposal_not_approval(self):
        package = {"schema_version": 1, "package_id": "fixture-1", "observations": [{
            "source_repository": "example/upstream", "target_repository": "owner/project",
            "relationship": "derived-from", "source_revision": "a" * 40,
            "target_revision": "b" * 40, "evidence_kind": "commit-patch",
            "locator": "commit:abc123", "confidence": "medium", "coverage": {"complete": True}
        }]}
        result = MODULE.archaeology_to_proposals(package)
        proposal = result["proposals"][0]
        self.assertEqual(proposal["decision_state"], "proposed-review-required")
        self.assertFalse(proposal["may_auto_approve"])
        self.assertFalse(result["authority"]["origins_declarations_modified"])
        self.assertFalse(result["authority"]["sync_or_ref_mutation"])

    def test_incomplete_evidence_never_becomes_confirmed(self):
        declarations = [{"source": "example/upstream", "relationship": "fork"}]
        proposals = [{"proposal_id": "p1", "source_repository": "example/upstream",
                      "relationship_candidate": "fork", "confidence": "high",
                      "coverage": {"complete": False}}]
        result = MODULE.reconcile(declarations, proposals)
        self.assertEqual(result["results"][0]["state"], "unavailable-or-incomplete")
        self.assertTrue(result["report_only"])

    def test_rejects_unversioned_or_malformed_evidence(self):
        with self.assertRaisesRegex(ValueError, "schema_version"):
            MODULE.archaeology_to_proposals({"schema_version": 2, "observations": []})
        with self.assertRaisesRegex(ValueError, "missing required fields"):
            MODULE.archaeology_to_proposals({"schema_version": 1, "observations": [{"source_repository": "x"}]})


if __name__ == "__main__":
    unittest.main()
