import unittest

from diagnostic_evidence import EvidenceCorrelationError, Provenance
from github_check_run_verifier import GitHubCheckRunVerifier

SHA = "a" * 40
PROVENANCE = Provenance("owner/repo", 12, 2, SHA)


class FakeAdapter:
    _deadline_seconds = 45

    def __init__(self, run=None, jobs=None, complete=True):
        self.run = run or {"id": 12, "run_attempt": 2, "head_sha": SHA}
        self.jobs = jobs if jobs is not None else [{
            "id": 91,
            "run_id": 12,
            "run_attempt": 2,
            "head_sha": SHA,
            "check_run_url": "https://api.github.com/repos/owner/repo/check-runs/7",
        }]
        self.complete = complete
        self.urls = []

    def _get_json(self, url, deadline):
        self.urls.append(url)
        return self.run, {}

    def _paginate(self, url, deadline):
        self.urls.append(url)
        return self.jobs, 1, self.complete


class GitHubCheckRunVerifierTests(unittest.TestCase):
    def test_proves_exact_attempt_and_check_run_to_job_link(self):
        adapter = FakeAdapter()
        self.assertEqual(GitHubCheckRunVerifier(adapter).verify(PROVENANCE, [7]), {7: 91})
        self.assertIn("/attempts/2", adapter.urls[0])
        self.assertIn("/attempts/2/jobs", adapter.urls[1])

    def test_rejects_wrong_attempt_metadata(self):
        adapter = FakeAdapter(run={"id": 12, "run_attempt": 1, "head_sha": SHA})
        with self.assertRaises(EvidenceCorrelationError):
            GitHubCheckRunVerifier(adapter).verify(PROVENANCE, [7])

    def test_rejects_wrong_head_sha(self):
        adapter = FakeAdapter(run={"id": 12, "run_attempt": 2, "head_sha": "b" * 40})
        with self.assertRaises(EvidenceCorrelationError):
            GitHubCheckRunVerifier(adapter).verify(PROVENANCE, [7])

    def test_rejects_unlinked_check_run(self):
        adapter = FakeAdapter(jobs=[{
            "id": 91, "run_id": 12, "run_attempt": 2, "head_sha": SHA,
            "check_run_url": "https://api.github.com/repos/owner/repo/check-runs/8",
        }])
        with self.assertRaises(EvidenceCorrelationError):
            GitHubCheckRunVerifier(adapter).verify(PROVENANCE, [7])

    def test_rejects_job_from_other_attempt_or_sha(self):
        adapter = FakeAdapter(jobs=[{
            "id": 91, "run_id": 12, "run_attempt": 1, "head_sha": SHA,
            "check_run_url": "https://api.github.com/repos/owner/repo/check-runs/7",
        }])
        with self.assertRaises(EvidenceCorrelationError):
            GitHubCheckRunVerifier(adapter).verify(PROVENANCE, [7])

    def test_rejects_noncanonical_check_run_url(self):
        adapter = FakeAdapter(jobs=[{
            "id": 91, "run_id": 12, "run_attempt": 2, "head_sha": SHA,
            "check_run_url": "https://attacker.example/repos/owner/repo/check-runs/7",
        }])
        with self.assertRaises(EvidenceCorrelationError):
            GitHubCheckRunVerifier(adapter).verify(PROVENANCE, [7])

    def test_rejects_incomplete_job_pagination(self):
        adapter = FakeAdapter(complete=False)
        with self.assertRaises(EvidenceCorrelationError):
            GitHubCheckRunVerifier(adapter).verify(PROVENANCE, [7])

    def test_rejects_duplicate_ids_before_network(self):
        adapter = FakeAdapter()
        with self.assertRaises(EvidenceCorrelationError):
            GitHubCheckRunVerifier(adapter).verify(PROVENANCE, [7, 7])
        self.assertEqual(adapter.urls, [])


if __name__ == "__main__":
    unittest.main()
