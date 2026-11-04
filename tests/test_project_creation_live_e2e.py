import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

from scripts.project_creation_live_e2e import (
    CANONICAL_REPOSITORY,
    disposable_repository_name,
    run_live_e2e,
)


ROOT = Path(__file__).resolve().parents[1]


class FakeAdapter:
    provider_id = "github"

    def __init__(self, verification=None, exists=False):
        self.verification = verification or {"metadata": True, "seeded_files": True}
        self.exists = exists
        self.created = []
        self.cleaned = []

    def capabilities(self):
        return {"repository_create_from_template"}

    def repository_exists(self, name):
        return self.exists

    def create_from_template(self, plan, idempotency_key):
        self.created.append((plan, idempotency_key))
        return {"repository": f"test-owner/{plan.repository_name}"}

    def verify_created_project(self, name, template):
        return self.verification

    def cleanup_created_repository(self, name):
        self.cleaned.append(name)
        return True


class ProjectCreationLiveE2ETests(unittest.TestCase):
    def run_case(self, adapter, **overrides):
        with tempfile.TemporaryDirectory() as temp:
            args = {
                "repository": CANONICAL_REPOSITORY,
                "confirmation": "CREATE-AND-DELETE",
                "owner": "test-owner",
                "token": "not-a-real-token",
                "run_id": "123456",
                "run_attempt": "2",
                "repository_root": ROOT,
                "journal_path": Path(temp) / "journal.sqlite3",
                "adapter": adapter,
            }
            args.update(overrides)
            return run_live_e2e(**args)


    def test_default_github_adapter_uses_user_account_endpoint(self):
        adapter = FakeAdapter()
        with patch(
            "scripts.project_creation_live_e2e.GitHubRepositoryAdapter",
            return_value=adapter,
        ) as adapter_factory:
            result = self.run_case(None)
        adapter_factory.assert_called_once_with(
            "test-owner", token="not-a-real-token", owner_type="user", timeout=20.0
        )
        self.assertEqual(result["status"], "verified")

    def test_name_is_unique_and_validated(self):
        self.assertEqual(disposable_repository_name("123", "4"), "fsa-live-e2e-123-4")
        with self.assertRaises(ValueError):
            disposable_repository_name("../unsafe", "1")

    def test_requires_exact_confirmation_before_provider_access(self):
        adapter = FakeAdapter()
        with self.assertRaises(PermissionError):
            self.run_case(adapter, confirmation="yes")
        self.assertEqual(adapter.created, [])
        self.assertEqual(adapter.cleaned, [])

    def test_executes_engine_verifies_journal_and_cleans_up(self):
        adapter = FakeAdapter()
        result = self.run_case(adapter)
        self.assertEqual(result["status"], "verified")
        self.assertEqual(result["journal_state"], "verified")
        self.assertEqual(result["cleanup"], "completed")
        self.assertEqual(len(adapter.created), 1)
        self.assertEqual(adapter.cleaned, ["fsa-live-e2e-123456-2"])

    def test_verification_failure_still_attempts_cleanup(self):
        adapter = FakeAdapter(verification={"metadata": False, "seeded_files": False})
        with self.assertRaisesRegex(RuntimeError, "did not reach verified"):
            self.run_case(adapter)
        self.assertEqual(adapter.cleaned, ["fsa-live-e2e-123456-2"])

    def test_existing_target_is_never_cleaned_up_or_overwritten(self):
        adapter = FakeAdapter(exists=True)
        with self.assertRaises(FileExistsError):
            self.run_case(adapter)
        self.assertEqual(adapter.created, [])
        self.assertEqual(adapter.cleaned, [])


if __name__ == "__main__":
    unittest.main()
