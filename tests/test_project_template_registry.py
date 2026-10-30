import tempfile
import unittest
from pathlib import Path

import yaml

from scripts.project_creation_engine import ProjectSpecError
from scripts.project_template_registry import load_registry, parse_registry, resolve_template


REGISTRY = {
    "schema_version": "1.0",
    "templates": [{
        "id": "generic-project",
        "version": "1.0.0",
        "description": "Generic project",
        "source": "registry://generic-project/1.0.0",
        "required_capabilities": ["repository_create_from_template"],
    }],
}


class RegistryTests(unittest.TestCase):
    def test_exact_version_resolution(self):
        templates = parse_registry(REGISTRY)
        self.assertEqual(resolve_template(templates, "generic-project", "1.0.0"), templates[0])

    def test_unknown_version_fails(self):
        with self.assertRaises(ProjectSpecError):
            resolve_template(parse_registry(REGISTRY), "generic-project", "2.0.0")

    def test_rejects_bad_schema_and_empty_registry(self):
        for raw in ({"schema_version": "2.0", "templates": REGISTRY["templates"]},
                    {"schema_version": "1.0", "templates": []}, None):
            with self.subTest(raw=raw), self.assertRaises(ProjectSpecError):
                parse_registry(raw)

    def test_rejects_duplicate_template_identity(self):
        raw = {"schema_version": "1.0", "templates": REGISTRY["templates"] * 2}
        with self.assertRaisesRegex(ProjectSpecError, "duplicate template identity"):
            parse_registry(raw)

    def test_rejects_bad_semver(self):
        entry = dict(REGISTRY["templates"][0], version="latest")
        with self.assertRaises(ProjectSpecError):
            parse_registry({"schema_version": "1.0", "templates": [entry]})

    def test_loads_yaml_and_rejects_duplicate_yaml_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "registry.yml"
            path.write_text(yaml.safe_dump(REGISTRY), encoding="utf-8")
            self.assertEqual(load_registry(path)[0].template_id, "generic-project")
            path.write_text('schema_version: "1.0"\nschema_version: "1.0"\ntemplates: []\n', encoding="utf-8")
            with self.assertRaises(ProjectSpecError):
                load_registry(path)


if __name__ == "__main__":
    unittest.main()
