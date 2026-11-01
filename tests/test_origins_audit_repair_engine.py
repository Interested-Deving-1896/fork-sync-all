import unittest
from pathlib import Path
import importlib.util

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "origins_audit_repair_engine.py"
spec = importlib.util.spec_from_file_location("origin_engine", SCRIPT)
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)

class NormalizeTests(unittest.TestCase):
    def test_valid_provenance_row(self):
        row = {"source":"owner/project", "url":"https://github.com/owner/project",
               "relationship":"reference", "what":"Used as reference"}
        result = engine.normalize(row)
        self.assertEqual(result["source"], "owner/project")
        self.assertEqual(result["registry_issues"], [])

    def test_invalid_relationship_reported(self):
        result = engine.normalize({"source":"bad", "url":"http://example.com",
                                  "relationship":"unknown"})
        self.assertIn("invalid-or-missing-source", result["registry_issues"])
        self.assertIn("unsupported-or-missing-url", result["registry_issues"])
        self.assertIn("invalid-or-missing-relationship", result["registry_issues"])

    def test_registry_only_does_not_network(self):
        report = engine.audit([{"source":"owner/project",
                               "url":"https://github.com/owner/project",
                               "relationship":"fork"}])
        self.assertEqual(report["origins"][0]["remote"]["status"], "not-checked")
        self.assertEqual(report["origin_count"], 1)

if __name__ == "__main__":
    unittest.main()
