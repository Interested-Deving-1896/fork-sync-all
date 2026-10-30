import unittest
from pathlib import Path

from scripts.project_creation_engine import ProjectSpecError, create_project
from scripts.project_creation_planner import prepare_project_creation


REPO_ROOT = Path(__file__).resolve().parents[1]


class DryRunAdapter:
    provider_id = "github"

    def capabilities(self):
        return {"repository_create_from_template"}

    def repository_exists(self, name):
        raise AssertionError("dry-run must not query a remote target")

    def create_from_template(self, plan, idempotency_key):
        raise AssertionError("dry-run must not mutate a provider")

    def verify_created_project(self, name, template):
        raise AssertionError("dry-run must not query a remote target")


class ProjectCreationPlannerTests(unittest.TestCase):
    def setUp(self):
        self.raw_spec = {
            "name": "example-project",
            "provider": "github",
            "template_id": "generic-project",
            "template_version": "1.0.0",
            "description": "A disposable planning fixture",
            "visibility": "private",
        }

    def test_preparation_resolves_bundle_and_embeds_verified_payload(self):
        prepared = prepare_project_creation(
            self.raw_spec,
            registry_path=REPO_ROOT / "config" / "project-template-registry.yml",
            repository_root=REPO_ROOT,
            provider_capabilities={"repository_create_from_template"},
        )
        self.assertEqual(prepared.plan.template_id, "generic-project")
        self.assertEqual(prepared.plan.template_version, "1.0.0")
        self.assertEqual(set(prepared.plan.template_files), {"README.md", ".gitignore"})
        self.assertEqual(set(prepared.plan.template_files), set(prepared.plan.template_sha256))
        self.assertEqual(prepared.plan.side_effects, ())

    def test_dry_run_uses_prepared_bundle_without_provider_mutation(self):
        prepared = prepare_project_creation(
            self.raw_spec,
            registry_path=REPO_ROOT / "config" / "project-template-registry.yml",
            repository_root=REPO_ROOT,
            provider_capabilities={"repository_create_from_template"},
        )
        result = create_project(
            prepared.spec,
            prepared.template,
            DryRunAdapter(),
            idempotency_key="planning-only",
            dry_run=True,
            template_bundle=prepared.bundle,
        )
        self.assertTrue(result["ok"])
        self.assertTrue(result["simulated"])
        self.assertEqual(result["plan"]["template_files"], dict(prepared.bundle.files))
        self.assertEqual(result["plan"]["template_sha256"], dict(prepared.bundle.sha256))

    def test_unknown_template_version_fails_closed(self):
        spec = dict(self.raw_spec, template_version="9.9.9")
        with self.assertRaises(ProjectSpecError):
            prepare_project_creation(
                spec,
                registry_path=REPO_ROOT / "config" / "project-template-registry.yml",
                repository_root=REPO_ROOT,
                provider_capabilities={"repository_create_from_template"},
            )

    def test_missing_provider_capability_fails_closed(self):
        with self.assertRaisesRegex(ProjectSpecError, "missing required capabilities"):
            prepare_project_creation(
                self.raw_spec,
                registry_path=REPO_ROOT / "config" / "project-template-registry.yml",
                repository_root=REPO_ROOT,
                provider_capabilities=set(),
            )


if __name__ == "__main__":
    unittest.main()
