import unittest

from scripts.audit_import_parity import compare


class ImportParityTests(unittest.TestCase):
    def test_identical_refs_and_default_branch_pass(self):
        refs = {"refs/heads/calamares": "a" * 40, "refs/tags/v1": "b" * 40}
        report = compare(refs, dict(refs), "calamares", "calamares")
        self.assertTrue(report["parity"])
        self.assertEqual(report["missing_on_target"], [])
        self.assertEqual(report["extra_on_target"], [])

    def test_missing_ref_fails(self):
        source = {"refs/heads/main": "a" * 40}
        report = compare(source, {}, "main", None)
        self.assertFalse(report["parity"])
        self.assertEqual(report["missing_on_target"], ["refs/heads/main"])

    def test_mismatched_ref_fails(self):
        source = {"refs/tags/v1": "a" * 40}
        target = {"refs/tags/v1": "b" * 40}
        report = compare(source, target, None, None)
        self.assertFalse(report["parity"])
        self.assertEqual(report["mismatched"][0]["ref"], "refs/tags/v1")

    def test_extra_ref_fails(self):
        target = {"refs/heads/obsolete": "c" * 40}
        report = compare({}, target, None, None)
        self.assertFalse(report["parity"])
        self.assertEqual(report["extra_on_target"], ["refs/heads/obsolete"])

    def test_default_branch_mismatch_fails_even_when_refs_match(self):
        refs = {"refs/heads/calamares": "a" * 40}
        report = compare(refs, dict(refs), "calamares", "1.1.x-stable")
        self.assertFalse(report["parity"])
        self.assertTrue(report["source_default_branch_present_on_target"])

    def test_no_default_branch_fails(self):
        refs = {"refs/heads/main": "a" * 40}
        report = compare(refs, dict(refs), None, "main")
        self.assertFalse(report["parity"])

    def test_audit_is_explicitly_read_only(self):
        report = compare({}, {}, None, None)
        self.assertEqual(report["mode"], "read-only")
        self.assertFalse(report["policy"]["writes"])
        self.assertFalse(report["policy"]["force_push"])
        self.assertFalse(report["policy"]["deletions"])



    @patch("scripts.audit_import_parity.subprocess.run")
    def test_list_refs_reads_symbolic_default_branch_from_first_field(self, run):
        from subprocess import CompletedProcess
        from scripts.audit_import_parity import list_refs

        run.return_value = CompletedProcess(
            args=["git", "ls-remote"], returncode=0,
            stdout=(
                "ref: refs/heads/calamares\\tHEAD\\n"
                + "a" * 40 + "\\tHEAD\\n"
                + "b" * 40 + "\\trefs/heads/calamares\\n"
            ),
            stderr="",
        )
        default_branch, refs = list_refs("https://example.invalid/source.git")
        self.assertEqual(default_branch, "calamares")
        self.assertEqual(refs["refs/heads/calamares"], "b" * 40)


if __name__ == "__main__":
    unittest.main()
