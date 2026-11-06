import json
import tempfile
import unittest
from pathlib import Path

from scripts.generational_migration_engine import (
    build_plan,
    classify_change,
    load_config,
    validate_config,
)

CONFIG = {
    "schema_version": "1.0",
    "project": {"id": "sample"},
    "generations": [
        {"id": "old", "repository": "org/old", "branch": "main"},
        {"id": "new", "repository": "org/new", "branch": "main"},
    ],
    "migration": {"source_generation": "old", "target_generation": "new"},
}


class GenerationalMigrationTests(unittest.TestCase):
    def test_config_loads(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps(CONFIG), encoding="utf-8")
            self.assertEqual(load_config(path)["schema_version"], "1.0")

    def test_requires_two_generations(self):
        config = {**CONFIG, "generations": CONFIG["generations"][:1]}
        with self.assertRaises(ValueError):
            validate_config(config)

    def test_rejects_duplicate_generation_ids(self):
        config = {
            **CONFIG,
            "generations": [CONFIG["generations"][0], CONFIG["generations"][0]],
        }
        with self.assertRaisesRegex(ValueError, "unique"):
            validate_config(config)

    def test_rejects_invalid_repository_identity(self):
        generation = {**CONFIG["generations"][0], "repository": "not-a-qualified-repo"}
        config = {**CONFIG, "generations": [generation, CONFIG["generations"][1]]}
        with self.assertRaisesRegex(ValueError, "owner/name"):
            validate_config(config)

    def test_accepts_project_specific_direction_identifiers(self):
        config = {
            **CONFIG,
            "migration": {
                "source_generation": "old",
                "target_generation": "new",
                "directions": ["old-to-new", "new-to-old"],
            },
        }
        self.assertIs(validate_config(config), config)

    def test_rejects_same_source_and_target(self):
        config = {
            **CONFIG,
            "migration": {"source_generation": "old", "target_generation": "old"},
        }
        with self.assertRaisesRegex(ValueError, "distinct"):
            validate_config(config)

    def test_docs_are_mechanical_candidates_not_automatic_edits(self):
        self.assertEqual(classify_change({"kind": "docs"}), "mechanical_candidate")
        plan = build_plan(CONFIG, [{"id": "D1", "kind": "docs"}])
        self.assertFalse(plan["safety"]["automatic_target_edits"])
        self.assertFalse(plan["safety"]["automatic_source_edits"])

    def test_unmapped_feature_is_manual(self):
        self.assertEqual(classify_change({"kind": "feature"}), "manual")

    def test_verified_bugfix_is_assisted(self):
        self.assertEqual(
            classify_change({"kind": "bugfix", "mapping_verified": True}),
            "assisted",
        )

    def test_unverified_security_change_is_manual(self):
        self.assertEqual(classify_change({"kind": "security"}), "manual")

    def test_plan_records_provenance_and_repository_identity(self):
        plan = build_plan(
            CONFIG,
            [{"id": "C1", "kind": "feature", "source_commit": "abc123"}],
        )
        self.assertEqual(plan["items"][0]["status"], "planned")
        self.assertEqual(plan["items"][0]["source_commit"], "abc123")
        self.assertTrue(plan["items"][0]["requires_human_review"])
        self.assertEqual(plan["source_repository"], "org/old")
        self.assertEqual(plan["target_repository"], "org/new")
        self.assertFalse(plan["safety"]["upstream_sync_performed"])

    def test_rejects_non_object_change_records(self):
        with self.assertRaisesRegex(ValueError, "each change record"):
            build_plan(CONFIG, ["not-an-object"])

    def test_rejects_non_list_mapping(self):
        with self.assertRaisesRegex(ValueError, "mapping must be a list"):
            build_plan(CONFIG, [{"id": "C2", "mapping": {"from": "x"}}])


if __name__ == "__main__":
    unittest.main()
