import base64
import hashlib
import unittest
from dataclasses import replace
from unittest.mock import patch

from scripts.project_creation_engine import CreationPlan, ProjectSpecError, Template
from scripts.project_creation_github_adapter import (
    GitHubRepositoryAdapter,
)


class GitHubRepositoryAdapterTests(unittest.TestCase):
    def setUp(self):
        self.adapter = GitHubRepositoryAdapter("alice", token="test-token")
        self.files = {"README.md": "# Generic project\n", "src/main.txt": "hello\n"}
        self.checksums = {
            path: hashlib.sha256(content.encode("utf-8")).hexdigest()
            for path, content in self.files.items()
        }
        self.plan = CreationPlan(
            provider="github",
            repository_name="sample-project",
            template_id="generic-project",
            template_version="1.0.0",
            description="Adapter test",
            visibility="private",
            required_capabilities=("repository_create_from_template",),
            template_files=self.files,
            template_sha256=self.checksums,
        )
        self.template = Template(
            template_id="generic-project",
            version="1.0.0",
            description="Generic project",
            source="registry://generic-project/1.0.0",
            required_capabilities=("repository_create_from_template",),
        )

    def test_requires_token_and_valid_owner_type(self):
        with patch.dict("os.environ", {}, clear=True):
            with self.assertRaisesRegex(ValueError, "token"):
                GitHubRepositoryAdapter("alice", token=None)
        with self.assertRaisesRegex(ValueError, "owner_type"):
            GitHubRepositoryAdapter("alice", token="x", owner_type="enterprise")

    def test_repository_exists_handles_only_404_as_absent(self):
        with patch.object(self.adapter, "_request", return_value=None) as request:
            self.assertFalse(self.adapter.repository_exists("sample-project"))
            request.assert_called_once_with(
                "GET", "/repos/alice/sample-project", allow_not_found=True
            )
        with patch.object(self.adapter, "_request", return_value={"name": "sample-project"}):
            self.assertTrue(self.adapter.repository_exists("sample-project"))

    def test_rejects_unsafe_template_paths_before_provider_mutation(self):
        unsafe_plan = replace(
            self.plan,
            template_files={"../escape.txt": "bad"},
            template_sha256={"../escape.txt": hashlib.sha256(b"bad").hexdigest()},
        )
        with patch.object(self.adapter, "_request") as request:
            with self.assertRaises(ProjectSpecError):
                self.adapter.create_from_template(unsafe_plan, "key")
            request.assert_not_called()

    def test_personal_owner_mismatch_fails_before_creation(self):
        with patch.object(self.adapter, "_request", return_value={"login": "mallory"}) as request:
            with self.assertRaisesRegex(ProjectSpecError, "authenticated GitHub user"):
                self.adapter.create_from_template(self.plan, "key")
            self.assertEqual(request.call_count, 1)
            self.assertEqual(request.call_args.args[:2], ("GET", "/user"))

    def test_create_seeds_files_and_verifies_metadata_and_contents(self):
        repo = {
            "name": "sample-project",
            "full_name": "alice/sample-project",
            "private": True,
            "visibility": "private",
        }
        calls = []

        def fake_request(method, path, payload=None, *, allow_not_found=False):
            calls.append((method, path, payload))
            if method == "GET" and path == "/user":
                return {"login": "alice"}
            if method == "POST" and path == "/user/repos":
                return repo
            if method == "PUT" and "/contents/" in path:
                return {"content": {"path": path.rsplit("/contents/", 1)[-1]}}
            if method == "GET" and path == "/repos/alice/sample-project":
                return repo
            if method == "GET" and path.endswith("/contents/README.md"):
                return {
                    "encoding": "base64",
                    "content": base64.b64encode(self.files["README.md"].encode()).decode(),
                }
            if method == "GET" and path.endswith("/contents/src/main.txt"):
                return {
                    "encoding": "base64",
                    "content": base64.b64encode(self.files["src/main.txt"].encode()).decode(),
                }
            raise AssertionError(f"unexpected mocked request: {method} {path}")

        with patch.object(self.adapter, "_request", side_effect=fake_request):
            result = self.adapter.create_from_template(self.plan, "stable-key")
            verified = self.adapter.verify_created_project("sample-project", self.template)

        self.assertEqual(result["repository"], "alice/sample-project")
        self.assertEqual(set(result["seeded_paths"]), set(self.files))
        self.assertEqual(verified, {"metadata": True, "seeded_files": True})
        self.assertEqual(sum(1 for method, path, _ in calls if method == "PUT"), 2)

    def test_verification_fails_closed_for_wrong_checksum(self):
        repo = {
            "name": "sample-project",
            "full_name": "alice/sample-project",
            "private": True,
            "visibility": "private",
        }

        def fake_request(method, path, payload=None, *, allow_not_found=False):
            if method == "GET" and path == "/repos/alice/sample-project":
                return repo
            if method == "GET" and path.endswith("/contents/README.md"):
                return {"encoding": "base64", "content": base64.b64encode(b"tampered").decode()}
            if method == "GET" and path.endswith("/contents/src/main.txt"):
                return {"encoding": "base64", "content": base64.b64encode(self.files["src/main.txt"].encode()).decode()}
            return None

        with patch.object(self.adapter, "_request", side_effect=fake_request):
            self.adapter._verification_expectations["sample-project"] = {
                "visibility": "private",
                "template_id": "generic-project",
                "template_version": "1.0.0",
                "files": dict(self.files),
                "checksums": dict(self.checksums),
            }
            verified = self.adapter.verify_created_project("sample-project", self.template)
        self.assertTrue(verified["metadata"])
        self.assertFalse(verified["seeded_files"])

    def test_verification_rejects_template_identity_mismatch(self):
        repo = {
            "name": "sample-project",
            "full_name": "alice/sample-project",
            "private": True,
            "visibility": "private",
        }
        with patch.object(self.adapter, "_request", return_value=repo):
            self.adapter._verification_expectations["sample-project"] = {
                "visibility": "private",
                "template_id": "generic-project",
                "template_version": "1.0.0",
                "files": dict(self.files),
                "checksums": dict(self.checksums),
            }
            other_template = replace(self.template, version="2.0.0")
            verified = self.adapter.verify_created_project("sample-project", other_template)
        self.assertFalse(verified["metadata"])
        self.assertFalse(verified["seeded_files"])

    def test_verification_rejects_noncanonical_base64(self):
        repo = {
            "name": "sample-project",
            "full_name": "alice/sample-project",
            "private": True,
            "visibility": "private",
        }

        def fake_request(method, path, payload=None, *, allow_not_found=False):
            if method == "GET" and path == "/repos/alice/sample-project":
                return repo
            if method == "GET" and path.endswith("/contents/README.md"):
                return {"encoding": "base64", "content": "!!" + base64.b64encode(self.files["README.md"].encode()).decode()}
            if method == "GET" and path.endswith("/contents/src/main.txt"):
                return {
                    "encoding": "base64",
                    "content": base64.b64encode(self.files["src/main.txt"].encode()).decode(),
                }
            return None

        with patch.object(self.adapter, "_request", side_effect=fake_request):
            self.adapter._verification_expectations["sample-project"] = {
                "visibility": "private",
                "template_id": "generic-project",
                "template_version": "1.0.0",
                "files": dict(self.files),
                "checksums": dict(self.checksums),
            }
            verified = self.adapter.verify_created_project("sample-project", self.template)
        self.assertTrue(verified["metadata"])
        self.assertFalse(verified["seeded_files"])



if __name__ == "__main__":
    unittest.main()
