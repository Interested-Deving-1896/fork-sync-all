"""Contract tests for the GitHub mirror-chain adapter."""
import unittest

from engines.mirror_chain import ProvisioningError, RepositoryRef, Strategy
from engines.mirror_chain.github import GitHubRepositoryProvider


class FakeGitHubClient:
    def __init__(self):
        self.repositories = {}
        self.fork_requests = []
        self.fail_request = False

    def get_repository(self, owner, name):
        return self.repositories.get(f"{owner}/{name}")

    def request_fork(self, source_owner, source_name, destination_org):
        if self.fail_request:
            raise RuntimeError("permission denied")
        self.fork_requests.append((source_owner, source_name, destination_org))
        source = self.repositories[f"{source_owner}/{source_name}"]
        self.repositories[f"{destination_org}/{source_name}"] = {
            "id": 202,
            "full_name": f"{destination_org}/{source_name}",
            "fork": True,
            "parent": {"id": source["id"]},
            "source": {"id": source["id"]},
            "archived": False,
        }
        return {"accepted": True}


class GitHubAdapterTests(unittest.TestCase):
    def setUp(self):
        self.client = FakeGitHubClient()
        self.client.repositories["canonical/project"] = {
            "id": 101, "full_name": "canonical/project", "fork": False,
            "archived": False,
        }
        self.adapter = GitHubRepositoryProvider(self.client)
        self.source_ref = RepositoryRef("github", "canonical", "project", "101")
        self.source = self.adapter.resolve(self.source_ref)
        self.destination = RepositoryRef("github", "mirror-org", "project")

    def test_resolve_returns_immutable_id_and_canonical_identity(self):
        state = self.adapter.resolve(self.source_ref)
        self.assertEqual(state.ref.repository_id, "101")
        self.assertEqual(state.ref.coordinate, "github:canonical/project")
        self.assertFalse(state.is_fork)

    def test_missing_repository_is_explicitly_absent(self):
        missing = self.adapter.resolve(self.destination)
        self.assertFalse(missing.exists)

    def test_native_fork_request_is_refetched_and_verified(self):
        created = self.adapter.create_native_fork(self.source, self.destination)
        self.assertTrue(created.exists)
        self.assertTrue(created.is_fork)
        self.assertEqual(created.parent_id, "101")
        self.assertEqual(created.ref.repository_id, "202")
        self.assertEqual(self.client.fork_requests, [("canonical", "project", "mirror-org")])

    def test_redirected_fork_response_preserves_actual_coordinate(self):
        self.client.repositories["mirror-org/project"] = {
            "id": 202, "full_name": "other-org/project", "fork": True,
            "parent": {"id": 101},
        }
        state = self.adapter.resolve(self.destination)
        self.assertEqual(state.ref.owner, "other-org")
        self.assertNotEqual(state.ref.coordinate, self.destination.coordinate)

    def test_provider_errors_are_not_treated_as_absent(self):
        self.client.fail_request = True
        with self.assertRaisesRegex(RuntimeError, "permission denied"):
            self.adapter.create_native_fork(self.source, self.destination)

    def test_clone_mirror_fails_closed_without_partial_write(self):
        with self.assertRaisesRegex(ProvisioningError, "not implemented"):
            self.adapter.create_clone_mirror(self.source, self.destination)
        self.assertEqual(self.client.fork_requests, [])

    def test_wrong_provider_is_rejected(self):
        ref = RepositoryRef("gitlab", "group", "project")
        with self.assertRaisesRegex(ProvisioningError, "cannot resolve"):
            self.adapter.resolve(ref)


if __name__ == "__main__":
    unittest.main()
