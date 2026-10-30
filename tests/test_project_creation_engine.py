import unittest

from scripts.project_creation_engine import (
    ProjectSpecError,
    Template,
    build_plan,
    create_project,
    validate_project_spec,
    validate_template,
)


class FakeAdapter:
    provider_id = "github"

    def __init__(self, exists=False, verification=None, creation_result=None):
        self.exists = exists
        self.created = []
        self.verified = []
        self.verification = {"metadata": True, "seeded_files": True} if verification is None else verification
        self.creation_result = {"name": "pipeline-test"} if creation_result is None else creation_result

    def capabilities(self):
        return {"repository_create_from_template"}

    def repository_exists(self, name):
        return self.exists

    def create_from_template(self, plan, idempotency_key):
        self.created.append((plan, idempotency_key))
        return self.creation_result

    def verify_created_project(self, name, template):
        self.verified.append((name, template.template_id))
        return self.verification


class ProjectCreationEngineTests(unittest.TestCase):
    def setUp(self):
        self.template = validate_template({
            "id": "generic-project",
            "version": "1.0.0",
            "description": "Generic project",
            "source": "registry://generic-project/1.0.0",
            "required_capabilities": ["repository_create_from_template"],
        })
        self.spec = validate_project_spec({
            "name": "pipeline-test",
            "provider": "github",
            "template_id": "generic-project",
            "template_version": "1.0.0",
        })

    def test_validates_and_builds_plan_without_mirror_side_effects(self):
        plan = build_plan(self.spec, self.template, {"repository_create_from_template"})
        self.assertEqual(plan.side_effects, ())
        self.assertNotIn("mirror", " ".join(plan.operations))

    def test_rejects_invalid_repository_name(self):
        with self.assertRaises(ProjectSpecError):
            validate_project_spec({
                "name": "../unsafe", "provider": "github",
                "template_id": "generic-project", "template_version": "1.0.0",
            })

    def test_rejects_mismatched_template_version(self):
        with self.assertRaises(ProjectSpecError):
            build_plan(self.spec, Template("generic-project", "2.0.0", "x", "registry://x"),
                       {"repository_create_from_template"})

    def test_rejects_missing_provider_capability(self):
        with self.assertRaises(ProjectSpecError):
            build_plan(self.spec, self.template, set())

    def test_dry_run_never_calls_mutation_adapter(self):
        adapter = FakeAdapter()
        result = create_project(self.spec, self.template, adapter,
                                idempotency_key="test-1", dry_run=True)
        self.assertTrue(result["simulated"])
        self.assertEqual(adapter.created, [])

    def test_mutation_requires_explicit_authorization(self):
        with self.assertRaises(PermissionError):
            create_project(self.spec, self.template, FakeAdapter(),
                           idempotency_key="test-2", dry_run=False)

    def test_existing_target_is_not_overwritten(self):
        adapter = FakeAdapter(exists=True)
        result = create_project(self.spec, self.template, adapter,
                                idempotency_key="test-3", dry_run=False,
                                authorize_mutation=True)
        self.assertEqual(result["status"], "conflict")
        self.assertEqual(adapter.created, [])

    def test_authorized_fake_adapter_creation_is_verified(self):
        adapter = FakeAdapter()
        result = create_project(self.spec, self.template, adapter,
                                idempotency_key="test-4", dry_run=False,
                                authorize_mutation=True)
        self.assertEqual(result["status"], "verified")
        self.assertEqual(result["mirror_propagation"], "not_requested")
        self.assertEqual(len(adapter.verified), 1)

    def test_rejects_control_characters_in_idempotency_key(self):
        for key in ("x\n", "x\r", "x\x00"):
            with self.subTest(key=repr(key)):
                with self.assertRaises(ProjectSpecError):
                    create_project(self.spec, self.template, FakeAdapter(),
                                   idempotency_key=key, dry_run=True)

    def test_rejects_duplicate_capabilities(self):
        with self.assertRaises(ProjectSpecError):
            validate_template({
                "id": "generic-project", "version": "1.0.0",
                "description": "Generic project", "source": "registry://x",
                "required_capabilities": ["repository_create_from_template",
                                          "repository_create_from_template"],
            })

    def test_rejects_provider_adapter_mismatch_before_mutation(self):
        adapter = FakeAdapter()
        adapter.provider_id = "gitlab"
        with self.assertRaises(ProjectSpecError):
            create_project(self.spec, self.template, adapter,
                           idempotency_key="provider-mismatch", dry_run=False,
                           authorize_mutation=True)
        self.assertEqual(adapter.created, [])

    def test_verification_requires_both_explicit_affirmative_checks(self):
        invalid_evidence = (
            {"metadata": False, "seeded_files": False},
            {"metadata": True, "seeded_files": False},
            {"metadata": True},
            {},
            None,
            {"metadata": 1, "seeded_files": True},
        )
        for evidence in invalid_evidence:
            with self.subTest(evidence=evidence):
                adapter = FakeAdapter(verification=evidence)
                result = create_project(self.spec, self.template, adapter,
                                        idempotency_key="verify-evidence",
                                        dry_run=False, authorize_mutation=True)
                self.assertFalse(result["ok"])
                self.assertEqual(result["status"], "verification_failed")
                self.assertEqual(result["mirror_propagation"], "not_requested")

    def test_invalid_creation_result_is_not_verified(self):
        adapter = FakeAdapter(creation_result=None)
        result = create_project(self.spec, self.template, adapter,
                                idempotency_key="invalid-creation",
                                dry_run=False, authorize_mutation=True)
        self.assertFalse(result["ok"])
        self.assertEqual(result["status"], "creation_result_invalid")
        self.assertEqual(adapter.verified, [])


if __name__ == "__main__":
    unittest.main()
