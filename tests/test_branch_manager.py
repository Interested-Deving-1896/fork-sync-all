"""Offline regression tests for the read-only branch manager CLI."""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "branch-manager.py"
SPEC = importlib.util.spec_from_file_location("branch_manager", SCRIPT)
branch_manager = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(branch_manager)


def run_git(cwd: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=cwd, text=True, capture_output=True, check=True
    )
    return result.stdout.strip()


class BranchManagerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.original_cwd = os.getcwd()
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name)
        run_git(self.repo, "init", "-b", "main")
        run_git(self.repo, "config", "user.name", "Branch Manager Tests")
        run_git(self.repo, "config", "user.email", "branch-manager@example.invalid")
        (self.repo / "seed.txt").write_text("seed\n", encoding="utf-8")
        run_git(self.repo, "add", "seed.txt")
        run_git(self.repo, "commit", "-m", "seed")
        main_sha = run_git(self.repo, "rev-parse", "HEAD")
        run_git(self.repo, "branch", "topic")
        run_git(self.repo, "update-ref", "refs/remotes/origin/main", main_sha)
        run_git(self.repo, "config", "branch.topic.remote", "origin")
        run_git(self.repo, "config", "branch.topic.merge", "refs/heads/main")
        # The production CLI runs Git commands in the process working directory.
        # Keep direct function calls isolated to this test's temporary repository.
        os.chdir(self.repo)

    def tearDown(self) -> None:
        os.chdir(self.original_cwd)
        self.temp.cleanup()

    def test_inventory_distinguishes_local_and_remote_tracking_refs(self) -> None:
        data = branch_manager.inventory()
        refs = {(item["name"], item["ref_kind"]) for item in data["branches"]}
        self.assertIn(("main", "local"), refs)
        self.assertIn(("topic", "local"), refs)
        self.assertIn(("origin/main", "remote_tracking"), refs)
        self.assertEqual(data["current_branch"], "main")
        self.assertIn("may be stale", data["remote_state_note"])

    def test_graph_labels_configured_upstream_and_policy_only_edge(self) -> None:
        graph = branch_manager.relationships(branch_manager.inventory())
        edges = graph["relationships"]
        self.assertIn(
            {"from": "topic", "to": "origin/main",
             "kind": "configured_upstream_external",
             "evidence": "Git branch upstream configuration"},
            edges,
        )
        self.assertIn(
            {"from": "main", "to": "topic",
             "kind": "default_policy_source_only",
             "evidence": "Policy default; not proof of ancestry or branch creation point"},
            edges,
        )

    def test_cli_json_status_explicitly_reports_no_mutations(self) -> None:
        before = run_git(self.repo, "for-each-ref", "--format=%(refname) %(objectname)")
        result = subprocess.run(
            ["python3", str(SCRIPT), "status", "--format", "json"],
            cwd=self.repo, text=True, capture_output=True, check=True,
        )
        status = json.loads(result.stdout)
        after = run_git(self.repo, "for-each-ref", "--format=%(refname) %(objectname)")
        self.assertFalse(status["mutations_performed"])
        self.assertEqual(before, after)
        self.assertEqual(status["local_branch_count"], 2)
        self.assertEqual(status["remote_tracking_branch_count"], 1)

    def test_explain_rejects_unknown_branch(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "Branch not found"):
            branch_manager.explain(branch_manager.relationships(branch_manager.inventory()), "missing")


if __name__ == "__main__":
    unittest.main()
