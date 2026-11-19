"""Offline tests for bounded Actions attempt/log retrieval."""
import io
import json
import unittest
from zipfile import ZipFile

from scripts.github_actions_log_adapter import GitHubActionsLogAdapter, RetrievalError


RUN_ID = 123
ATTEMPT = 2
SHA = "a" * 40
TOKEN = "ghp_" + "x" * 36


def archive():
    stream = io.BytesIO()
    with ZipFile(stream, "w") as zf:
        zf.writestr("build/1_Test.txt", "2026-01-01T00:00:00.000Z ::error:: failure")
    return stream.getvalue()


class FakeTransport:
    def __init__(self, *, wrong_run=False, unsafe_redirect=False):
        self.calls = []
        self.wrong_run = wrong_run
        self.unsafe_redirect = unsafe_redirect

    def __call__(self, url, headers, timeout, max_bytes):
        self.calls.append((url, dict(headers)))
        if url.endswith(f"/attempts/{ATTEMPT}"):
            data = {"id": RUN_ID + (1 if self.wrong_run else 0),
                    "run_attempt": ATTEMPT, "head_sha": SHA}
            return 200, {}, json.dumps(data).encode()
        if "/jobs?" in url:
            data = {"jobs": [{"id": 9, "run_id": RUN_ID,
                              "run_attempt": ATTEMPT, "head_sha": SHA}]}
            return 200, {}, json.dumps(data).encode()
        if url.endswith("/logs"):
            host = "https://evil.example/secret" if self.unsafe_redirect else "https://storage.example/signed?token=abc"
            return 302, {"Location": host}, b""
        if "storage.example" in url:
            return 200, {}, archive()
        raise AssertionError(url)


class ActionsLogAdapterTests(unittest.TestCase):
    def test_retrieves_exact_attempt_and_never_forwards_token_to_storage(self):
        transport = FakeTransport()
        result = GitHubActionsLogAdapter(TOKEN, request=transport).retrieve(
            "owner/repo", RUN_ID, ATTEMPT, SHA)
        self.assertEqual(result.logs_status, "success")
        self.assertIn("build/1_Test.txt", result.log_files)
        storage_headers = [h for u, h in transport.calls if "storage.example" in u][0]
        self.assertNotIn("Authorization", storage_headers)
        api_headers = [h for u, h in transport.calls if "api.github.com" in u]
        self.assertTrue(all(h.get("Authorization") == f"Bearer {TOKEN}" for h in api_headers))

    def test_rejects_wrong_run_metadata(self):
        with self.assertRaisesRegex(RetrievalError, "does not match"):
            GitHubActionsLogAdapter(TOKEN, request=FakeTransport(wrong_run=True)).retrieve(
                "owner/repo", RUN_ID, ATTEMPT, SHA)

    def test_rejects_untrusted_redirect_target(self):
        with self.assertRaisesRegex(RetrievalError, "unsafe"):
            GitHubActionsLogAdapter(TOKEN, request=FakeTransport(unsafe_redirect=True)).retrieve(
                "owner/repo", RUN_ID, ATTEMPT, SHA)

    def test_rejects_wrong_job_attempt_or_sha(self):
        def transport(url, headers, timeout, max_bytes):
            if url.endswith(f"/attempts/{ATTEMPT}"):
                return 200, {}, json.dumps({"id": RUN_ID, "run_attempt": ATTEMPT,
                                            "head_sha": SHA}).encode()
            if "/jobs?" in url:
                return 200, {}, json.dumps({"jobs": [{"run_id": RUN_ID,
                    "run_attempt": ATTEMPT - 1, "head_sha": SHA}]}).encode()
            raise AssertionError("logs must not be fetched after invalid jobs")
        with self.assertRaisesRegex(RetrievalError, "job metadata"):
            GitHubActionsLogAdapter(TOKEN, request=transport).retrieve(
                "owner/repo", RUN_ID, ATTEMPT, SHA)


if __name__ == "__main__":
    unittest.main()
