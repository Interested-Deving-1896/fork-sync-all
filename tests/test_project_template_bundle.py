import hashlib
import tempfile
import unittest
from pathlib import Path

import yaml

from scripts.project_creation_engine import ProjectSpecError
from scripts.project_template_bundle import resolve_template_bundle
from scripts.project_template_registry import load_registry, resolve_template


REPO_ROOT = Path(__file__).resolve().parents[1]
TEMPLATE_ID = "generic-project"
VERSION = "1.0.0"


def _write_bundle(root: Path, *, relative="README.md", file_content="hello\n", source=None,
                  manifest_id=TEMPLATE_ID, manifest_version=VERSION):
    bundle = root / "templates" / "project-creation" / TEMPLATE_ID / VERSION
    bundle.mkdir(parents=True)
    (bundle / relative).parent.mkdir(parents=True, exist_ok=True)
    (bundle / relative).write_text(file_content, encoding="utf-8")
    digest = hashlib.sha256(file_content.encode("utf-8")).hexdigest()
    manifest = {
        "schema_version": "1.0",
        "template_id": manifest_id,
        "version": manifest_version,
        "files": [{"path": relative, "sha256": digest}],
    }
    (bundle / "manifest.yml").write_text(yaml.safe_dump(manifest), encoding="utf-8")
    registry_source = source or f"registry://{TEMPLATE_ID}/{VERSION}"
    return type("TemplateLike", (), {})(), bundle, registry_source


class TemplateBundleTests(unittest.TestCase):
    def setUp(self):
        self.template = resolve_template(
            load_registry(REPO_ROOT / "config" / "project-template-registry.yml"),
            TEMPLATE_ID,
            VERSION,
        )

    def test_resolves_checked_in_bundle_and_verifies_hashes(self):
        bundle = resolve_template_bundle(self.template, REPO_ROOT)
        self.assertEqual(bundle.template_id, TEMPLATE_ID)
        self.assertEqual(bundle.version, VERSION)
        self.assertIn("README.md", bundle.files)
        self.assertIn(".gitignore", bundle.files)
        self.assertEqual(
            hashlib.sha256(bundle.files["README.md"].encode("utf-8")).hexdigest(),
            bundle.sha256["README.md"],
        )

    def test_rejects_unsupported_source_scheme(self):
        from dataclasses import replace
        with self.assertRaises(ProjectSpecError):
            resolve_template_bundle(replace(self.template, source="https://example.invalid/template"), REPO_ROOT)

    def test_rejects_uri_identity_mismatch(self):
        from dataclasses import replace
        with self.assertRaises(ProjectSpecError):
            resolve_template_bundle(replace(self.template, source="registry://other-project/1.0.0"), REPO_ROOT)

    def test_rejects_modified_file_checksum(self):
        from dataclasses import replace
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / "templates" / "project-creation" / TEMPLATE_ID / VERSION
            bundle.mkdir(parents=True)
            (bundle / "README.md").write_text("changed\n", encoding="utf-8")
            (bundle / "manifest.yml").write_text(yaml.safe_dump({
                "schema_version": "1.0", "template_id": TEMPLATE_ID, "version": VERSION,
                "files": [{"path": "README.md", "sha256": "0" * 64}],
            }), encoding="utf-8")
            with self.assertRaisesRegex(ProjectSpecError, "checksum mismatch"):
                resolve_template_bundle(self.template, root)

    def test_rejects_parent_traversal(self):
        from dataclasses import replace
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / "templates" / "project-creation" / TEMPLATE_ID / VERSION
            bundle.mkdir(parents=True)
            (bundle / "manifest.yml").write_text(yaml.safe_dump({
                "schema_version": "1.0", "template_id": TEMPLATE_ID, "version": VERSION,
                "files": [{"path": "../outside.txt", "sha256": "0" * 64}],
            }), encoding="utf-8")
            with self.assertRaises(ProjectSpecError):
                resolve_template_bundle(self.template, root)

    def test_rejects_duplicate_manifest_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / "templates" / "project-creation" / TEMPLATE_ID / VERSION
            bundle.mkdir(parents=True)
            (bundle / "manifest.yml").write_text(
                'schema_version: "1.0"\nschema_version: "1.0"\ntemplate_id: generic-project\n'
                'version: "1.0.0"\nfiles: []\n', encoding="utf-8"
            )
            with self.assertRaises(ProjectSpecError):
                resolve_template_bundle(self.template, root)

    def test_rejects_symlinked_bundle_file(self):
        from dataclasses import replace
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            root = Path(directory)
            bundle = root / "templates" / "project-creation" / TEMPLATE_ID / VERSION
            bundle.mkdir(parents=True)
            external = Path(outside) / "outside.txt"
            external.write_text("safe-looking\n", encoding="utf-8")
            (bundle / "README.md").symlink_to(external)
            digest = hashlib.sha256(external.read_bytes()).hexdigest()
            (bundle / "manifest.yml").write_text(yaml.safe_dump({
                "schema_version": "1.0", "template_id": TEMPLATE_ID, "version": VERSION,
                "files": [{"path": "README.md", "sha256": digest}],
            }), encoding="utf-8")
            with self.assertRaises(ProjectSpecError):
                resolve_template_bundle(self.template, root)


if __name__ == "__main__":
    unittest.main()
