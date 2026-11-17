import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "loop_guard.py"
SPEC = importlib.util.spec_from_file_location("loop_guard", SCRIPT)
loop_guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(loop_guard)


class LoopGuardTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.ledger = Path(self.tempdir.name) / "events.jsonl"

    def tearDown(self):
        self.tempdir.cleanup()

    def record(self, **overrides):
        values = dict(
            engine="fetcher", action="get-log", target="repo/workflow/42",
            request_fingerprint="page=1", progress="cursor-1", now=1000,
            ledger=self.ledger,
        )
        values.update(overrides)
        return loop_guard.record_operation(**values)

    def test_repeated_unchanged_operation_is_flagged_at_threshold(self):
        self.assertFalse(self.record()["suspected_loop"])
        self.assertFalse(self.record()["suspected_loop"])
        result = self.record()
        self.assertTrue(result["suspected_loop"])
        self.assertEqual(result["repeat_count"], 3)
        self.assertEqual(result["mode"], "observe-only")

    def test_advancing_cursor_is_not_a_loop(self):
        self.record(progress="cursor-1")
        self.record(progress="cursor-2")
        result = self.record(progress="cursor-3")
        self.assertFalse(result["suspected_loop"])
        self.assertEqual(result["repeat_count"], 1)

    def test_independent_targets_are_not_combined(self):
        self.record(target="repo-a/log/42")
        self.record(target="repo-b/log/42")
        result = self.record(target="repo-c/log/42")
        self.assertEqual(result["repeat_count"], 1)

    def test_old_events_fall_outside_window(self):
        self.record(now=1000)
        result = self.record(now=2000, window_seconds=60)
        self.assertEqual(result["repeat_count"], 1)

    def test_ledger_is_bounded(self):
        for stamp in range(5):
            self.record(now=1000 + stamp, max_events=2)
        self.assertEqual(len(loop_guard._load_events(self.ledger)), 2)

    def test_required_fields_and_threshold_are_validated(self):
        with self.assertRaises(ValueError):
            self.record(action="")
        with self.assertRaises(ValueError):
            self.record(threshold=1)


if __name__ == "__main__":
    unittest.main()
