import tempfile
import unittest
from pathlib import Path

from scripts.project_creation_engine import ProjectSpec, Template, ProjectSpecError
from scripts.project_creation_journal import (
    IdempotencyConflict,
    SQLiteCreationJournal,
    create_project_with_journal,
)


class FakeAdapter:
    provider_id = "github"

    def __init__(self, *, exists=False, verification=None, raise_create=False):
        self.exists = exists
        self.verification = verification or {"metadata": True, "seeded_files": True}
        self.raise_create = raise_create
        self.create_calls = 0
        self.verify_calls = 0

    def capabilities(self):
        return {"repository_create_from_template"}

    def repository_exists(self, name):
        return self.exists

    def create_from_template(self, plan, idempotency_key):
        self.create_calls += 1
        if self.raise_create:
            raise RuntimeError("provider transport failed")
        return {"id": "fake-123"}

    def verify_created_project(self, name, template):
        self.verify_calls += 1
        return self.verification


class ProjectCreationJournalTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.db_path = Path(self.tempdir.name) / "journal.sqlite3"
        self.journal = SQLiteCreationJournal(self.db_path)
        self.spec = ProjectSpec(
            name="journal-fixture",
            provider="github",
            template_id="generic-project",
            template_version="1.0.0",
            description="Journal test",
            visibility="private",
        )
        self.template = Template(
            template_id="generic-project",
            version="1.0.0",
            description="Generic project",
            source="registry://generic-project/1.0.0",
            required_capabilities=("repository_create_from_template",),
        )

    def tearDown(self):
        self.tempdir.cleanup()

    def run_create(self, adapter, key="test-key", **kwargs):
        return create_project_with_journal(
            self.spec, self.template, adapter, self.journal,
            idempotency_key=key, dry_run=False, authorize_mutation=True, **kwargs
        )

    def test_verified_request_is_replayed_without_second_provider_mutation(self):
        adapter = FakeAdapter()
        first = self.run_create(adapter)
        second = self.run_create(adapter)
        self.assertEqual(first["status"], "verified")
        self.assertTrue(second["replayed"])
        self.assertEqual(adapter.create_calls, 1)
        self.assertEqual(adapter.verify_calls, 1)
        self.assertEqual(self.journal.get("test-key")["state"], "verified")

    def test_reusing_key_for_different_request_is_rejected(self):
        self.run_create(FakeAdapter())
        other = ProjectSpec(
            name="different-target", provider="github", template_id="generic-project",
            template_version="1.0.0", description="Different", visibility="private",
        )
        with self.assertRaises(IdempotencyConflict):
            create_project_with_journal(
                other, self.template, FakeAdapter(), self.journal,
                idempotency_key="test-key", dry_run=False, authorize_mutation=True,
            )

    def test_provider_exception_requires_reconciliation_and_never_retries(self):
        adapter = FakeAdapter(raise_create=True)
        first = self.run_create(adapter)
        second = self.run_create(adapter)
        self.assertEqual(first["status"], "reconciliation_required")
        self.assertEqual(second["status"], "reconciliation_required")
        self.assertEqual(adapter.create_calls, 1)
        self.assertEqual(self.journal.get("test-key")["state"], "reconciliation_required")

    def test_incomplete_verification_requires_reconciliation(self):
        adapter = FakeAdapter(verification={"metadata": True, "seeded_files": False})
        result = self.run_create(adapter)
        self.assertEqual(result["status"], "reconciliation_required")
        self.assertEqual(self.journal.get("test-key")["state"], "reconciliation_required")

    def test_dry_run_never_creates_journal_entry_or_calls_provider(self):
        adapter = FakeAdapter()
        result = create_project_with_journal(
            self.spec, self.template, adapter, self.journal,
            idempotency_key="dry-run", dry_run=True, authorize_mutation=True,
        )
        self.assertEqual(result["status"], "planned")
        self.assertIsNone(self.journal.get("dry-run"))
        self.assertEqual(adapter.create_calls, 0)

    def test_existing_target_is_not_overwritten(self):
        adapter = FakeAdapter(exists=True)
        result = self.run_create(adapter)
        self.assertEqual(result["status"], "conflict")
        self.assertEqual(adapter.create_calls, 0)

    def test_journal_survives_reopening_database(self):
        adapter = FakeAdapter()
        self.run_create(adapter)
        reopened = SQLiteCreationJournal(self.db_path)
        self.assertEqual(reopened.get("test-key")["state"], "verified")


if __name__ == "__main__":
    unittest.main()
