import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import sys
import unittest
from unittest import mock

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
    
    def test_current_provenance_file_is_covered_by_seed_parser(self):
        provenance = ROOT / "dep-graph" / "provenance.yml"
        source = provenance.read_text(encoding="utf-8")
        records = MODULE.parse_provenance_yaml(source)
        declared_count = sum(1 for line in source.splitlines() if line.strip().startswith("- source:"))
        self.assertEqual(len(records), declared_count)
        self.assertTrue(records)
        self.assertTrue(all(item.get("source") and item.get("url") and item.get("relationship") for item in records))
        self.assertTrue(all(item["relationship"] in MODULE.RELATIONSHIPS for item in records))

    def test_reconcile_cli_emits_report_only_json(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            provenance = root / "provenance.yml"
            proposals = root / "proposals.json"
            provenance.write_text(
                "influences:\n  - source: example/upstream\n    relationship: fork\n",
                encoding="utf-8")
            proposals.write_text(json.dumps({"proposals": [{
                "proposal_id": "p1", "source_repository": "example/upstream",
                "relationship_candidate": "fork", "confidence": "medium",
                "coverage": {"complete": True}
            }]}), encoding="utf-8")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                with mock.patch.object(sys, "argv", [
                    "origins_archaeology.py", "reconcile", "--provenance",
                    str(provenance), "--input", str(proposals)
                ]):
                    self.assertEqual(MODULE.main(), 0)
        report = json.loads(output.getvalue())
        self.assertTrue(report["report_only"])
        self.assertEqual(report["results"][0]["state"], "candidate-match")
        self.assertEqual(report["results"][0]["decision_state"], "human-review-required")


if __name__ == "__main__":
    unittest.main()
