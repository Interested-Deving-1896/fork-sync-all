import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from diagnostic_evidence import (
    EvidenceCorrelationError,
    EvidenceError,
    EvidenceRecord,
    Provenance,
    RetrievalStatus,
    build_audit_report,
    canonical_digest,
    normalize_annotation,
    redact_text,
    verify_correlation,
)

SHA = "a" * 40


def provenance(**overrides):
    values = dict(repository="owner/repo", run_id=12, attempt=2, head_sha=SHA,
                  job_id=34, check_run_id=56)
    values.update(overrides)
    return Provenance(**values)


class DiagnosticEvidenceTests(unittest.TestCase):
    def test_exact_run_attempt_and_sha_correlation(self):
        p = provenance()
        verify_correlation(p, {"repository": "owner/repo", "run_id": 12,
            "attempt": 2, "head_sha": SHA.upper(), "job_id": 34, "check_run_id": 56})

    def test_rejects_missing_or_mismatched_attempt(self):
        p = provenance()
        for observed in (
            {"repository": "owner/repo", "run_id": 12, "head_sha": SHA},
            {"repository": "owner/repo", "run_id": 12, "attempt": 1, "head_sha": SHA},
            {"repository": "owner/repo", "run_id": 12, "attempt": 2, "head_sha": "b" * 40},
        ):
            with self.subTest(observed=observed), self.assertRaises(EvidenceCorrelationError):
                verify_correlation(p, observed)

    def test_annotation_normalization_preserves_identity_and_redacts(self):
        result = normalize_annotation({
            "check_run_id": 56, "head_sha": SHA, "path": "src/app.py",
            "start_line": 4, "end_line": 5, "annotation_level": "failure",
            "title": "Auth", "message": "Authorization: Bearer abcdefghijklmnop",
        }, check_run_id=56, head_sha=SHA)
        self.assertEqual(result["path"], "src/app.py")
        self.assertIn("[REDACTED]", result["message"])

    def test_rejects_annotation_identity_mismatch(self):
        with self.assertRaises(EvidenceCorrelationError):
            normalize_annotation({"check_run_id": 9, "head_sha": SHA,
                "path": "a.py", "annotation_level": "warning"},
                check_run_id=56, head_sha=SHA)

    def test_rejects_unsafe_annotation_paths_and_ranges(self):
        for path in ("/etc/passwd", "../secret", "src/../../secret"):
            with self.subTest(path=path), self.assertRaises(EvidenceError):
                normalize_annotation({"check_run_id": 56, "head_sha": SHA,
                    "path": path, "annotation_level": "notice"},
                    check_run_id=56, head_sha=SHA)
        with self.assertRaises(EvidenceError):
            normalize_annotation({"check_run_id": 56, "head_sha": SHA,
                "path": "a.py", "annotation_level": "failure",
                "start_line": 8, "end_line": 2}, check_run_id=56, head_sha=SHA)

    def test_success_with_zero_annotations_is_valid(self):
        record = EvidenceRecord("1.0", "github.check-runs.annotations", provenance(),
            RetrievalStatus.SUCCESS, "2026-11-17T12:00:00Z", records=())
        report = build_audit_report([record])
        self.assertTrue(report["complete"])
        self.assertEqual(report["evidence"][0]["records"], [])

    def test_partial_retrieval_is_never_reported_complete(self):
        record = EvidenceRecord("1.0", "github.check-runs.annotations", provenance(),
            RetrievalStatus.PARTIAL, "2026-11-17T12:00:00+00:00",
            errors=("page 3 returned HTTP 429",), pages_read=2, pages_expected=3)
        self.assertFalse(build_audit_report([record])["complete"])

    def test_failure_classes_remain_distinct(self):
        statuses = [RetrievalStatus.UNAVAILABLE, RetrievalStatus.UNSUPPORTED,
                    RetrievalStatus.EXPIRED, RetrievalStatus.FAILED]
        records = [EvidenceRecord("1.0", "github.logs", provenance(), status,
            "2026-11-17T12:00:00Z") for status in statuses]
        report = build_audit_report(records)
        self.assertEqual([x["status"] for x in report["evidence"]],
            ["unavailable", "unsupported", "expired", "failed"])
        self.assertFalse(report["complete"])

    def test_redacts_common_tokens_and_signed_urls(self):
        value = "ghp_" + "x" * 30 + " https://logs.example/file?sig=secret"
        redacted = redact_text(value)
        self.assertNotIn("ghp_" + "x" * 30, redacted)
        self.assertNotIn("sig=secret", redacted)

    def test_digest_is_deterministic_and_redacted(self):
        secret = "github_pat_" + "z" * 30
        self.assertEqual(canonical_digest({"token": secret}),
                         canonical_digest({"token": "[REDACTED_GITHUB_TOKEN]"}))

    def test_partial_requires_explanation_and_success_rejects_errors(self):
        with self.assertRaises(EvidenceError):
            EvidenceRecord("1.0", "github.logs", provenance(), RetrievalStatus.PARTIAL,
                "2026-11-17T12:00:00Z")
        with self.assertRaises(EvidenceError):
            EvidenceRecord("1.0", "github.logs", provenance(), RetrievalStatus.SUCCESS,
                "2026-11-17T12:00:00Z", errors=("timeout",))


if __name__ == "__main__":
    unittest.main()
