import sys
from pathlib import Path
import unittest
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from diagnostic_evidence import Provenance, RetrievalStatus
from github_diagnostic_adapter import AdapterError, GitHubCheckRunsAdapter

SHA = "a" * 40
PROVENANCE = Provenance("owner/repo", 12, 2, SHA)


class FakeTransport:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def __call__(self, url, headers, timeout, max_bytes):
        self.calls.append((url, dict(headers), timeout, max_bytes))
        if not self.responses:
            raise AssertionError("unexpected extra request")
        return self.responses.pop(0)


class GitHubDiagnosticAdapterTests(unittest.TestCase):
    def adapter(self, fake, **kwargs):
        return GitHubCheckRunsAdapter("test-token", request=fake, sleep=lambda _: None,
                                      **kwargs)

    def test_fetches_all_annotation_pages_and_preserves_check_run_identity(self):
        fake = FakeTransport([
            (200, {"Link": '<https://api.github.com/repos/owner/repo/check-runs/7/annotations?per_page=100&page=2>; rel="next"'}, b'[{"path":"src/a.py","annotation_level":"warning","start_line":2}]'),
            (200, {}, b'[{"path":"src/b.py","annotation_level":"failure","end_line":4}]'),
        ])
        record = self.adapter(fake).fetch_annotations(PROVENANCE, [7])
        self.assertEqual(record.status, RetrievalStatus.SUCCESS)
        self.assertEqual(record.pages_read, 2)
        self.assertEqual(len(record.records), 2)
        self.assertEqual({x["check_run_id"] for x in record.records}, {7})
        self.assertTrue(all(x["head_sha"] == SHA for x in record.records))
        self.assertTrue(all(call[1]["Authorization"] == "Bearer test-token" for call in fake.calls))

    def test_zero_annotations_is_a_successful_empty_result(self):
        fake = FakeTransport([(200, {}, b'[]')])
        record = self.adapter(fake).fetch_annotations(PROVENANCE, [7])
        self.assertEqual(record.status, RetrievalStatus.SUCCESS)
        self.assertEqual(record.records, ())

    def test_permission_denial_is_unavailable_not_clean_or_generic_failure(self):
        fake = FakeTransport([(403, {}, b'{"message":"forbidden"}')])
        record = self.adapter(fake, retries=0).fetch_annotations(PROVENANCE, [7])
        self.assertEqual(record.status, RetrievalStatus.UNAVAILABLE)
        self.assertTrue(record.errors)

    def test_rate_limited_forbidden_response_is_failed_not_permission_unavailable(self):
        fake = FakeTransport([(403, {"X-RateLimit-Remaining": "0"}, b'{"message":"API rate limit exceeded"}')])
        record = self.adapter(fake, retries=0).fetch_annotations(PROVENANCE, [7])
        self.assertEqual(record.status, RetrievalStatus.FAILED)

    def test_expired_annotation_endpoint_is_explicit(self):
        fake = FakeTransport([(410, {}, b'{"message":"expired"}')])
        record = self.adapter(fake, retries=0).fetch_annotations(PROVENANCE, [7])
        self.assertEqual(record.status, RetrievalStatus.EXPIRED)
        self.assertTrue(record.errors)

    def test_page_limit_produces_partial_evidence(self):
        link = '<https://api.github.com/next>; rel="next"'
        fake = FakeTransport([(200, {"Link": link}, b'[{"path":"a.py","annotation_level":"notice"}]')])
        record = self.adapter(fake, max_pages=1).fetch_annotations(PROVENANCE, [7])
        self.assertEqual(record.status, RetrievalStatus.PARTIAL)
        self.assertEqual(record.pages_read, 1)

    def test_retries_rate_limit_with_bounded_retry_after(self):
        fake = FakeTransport([(429, {"Retry-After": "1"}, b'{}'), (200, {}, b'[]')])
        record = self.adapter(fake).fetch_annotations(PROVENANCE, [7])
        self.assertEqual(record.status, RetrievalStatus.SUCCESS)
        self.assertEqual(len(fake.calls), 2)

    def test_rejects_duplicate_and_unverified_ids(self):
        fake = FakeTransport([])
        adapter = self.adapter(fake)
        with self.assertRaises(ValueError):
            adapter.fetch_annotations(PROVENANCE, [7, 7])
        self.assertEqual(fake.calls, [])

    def test_authentication_is_never_sent_to_non_api_origin(self):
        fake = FakeTransport([])
        adapter = self.adapter(fake)
        with self.assertRaises(AdapterError):
            adapter._get_json("https://example.com/steal", 10**12)
        self.assertEqual(fake.calls, [])


if __name__ == "__main__":
    unittest.main()
