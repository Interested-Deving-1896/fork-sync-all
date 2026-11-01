import json
import tempfile
import unittest
from pathlib import Path
from scripts.generational_migration_engine import load_config, classify_change, build_plan

CONFIG = {
    "schema_version":"1.0",
    "project":{"id":"sample"},
    "generations":[
        {"id":"old","repository":"org/old","branch":"main"},
        {"id":"new","repository":"org/new","branch":"main"}
    ],
    "migration":{"source_generation":"old","target_generation":"new"}
}

class GenerationalMigrationTests(unittest.TestCase):
    def test_config_loads(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/"c.json"; p.write_text(json.dumps(CONFIG))
            self.assertEqual(load_config(p)["schema_version"],"1.0")

    def test_requires_two_generations(self):
        c=dict(CONFIG); c["generations"]=CONFIG["generations"][:1]
        with self.assertRaises(ValueError): build_plan(c,[])

    def test_docs_are_mechanical_candidate(self):
        self.assertEqual(classify_change({"kind":"docs"}),"mechanical_candidate")

    def test_unmapped_feature_is_manual(self):
        self.assertEqual(classify_change({"kind":"feature"}),"manual")

    def test_verified_bugfix_is_assisted(self):
        self.assertEqual(classify_change({"kind":"bugfix","mapping_verified":True}),"assisted")

    def test_plan_is_non_mutating_and_reviewable(self):
        plan=build_plan(CONFIG,[{"id":"C1","kind":"feature","source_commit":"abc"}])
        self.assertEqual(plan["items"][0]["status"],"planned")
        self.assertTrue(plan["items"][0]["requires_human_review"])
        self.assertFalse(plan["safety"]["automatic_source_edits"])

if __name__ == "__main__":
    unittest.main()
