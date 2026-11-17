"""Regression checks for the temporary mirror development hold."""
from pathlib import Path
import unittest

ROOT = Path(__file__).parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"


class MirrorWorkflowHoldTests(unittest.TestCase):
    def test_legacy_mirror_writers_are_manual_noop_holds(self):
        paused = [
            "mirror-osp-to-ooc.yaml",
            "setup-osp-mirrors.yml",
            "mirror-orgs-full.yml",
            "mirror-osp-to-gitlab.yml",
            "git-platform-sync.yml",
            "mirror.yaml",
            "mirror-chain-dispatch.yml",
            "add-mirror-repo.yml",
        ]
        for name in paused:
            with self.subTest(workflow=name):
                text = (WORKFLOWS / name).read_text()
                self.assertIn("workflow_dispatch:", text)
                self.assertNotIn("schedule:", text)
                self.assertNotIn("push:", text)
                self.assertNotIn("secrets.", text)
                self.assertNotIn("git push", text)

    def test_source_to_osp_is_pinned_read_only(self):
        text = (WORKFLOWS / "mirror-to-osp.yml").read_text()
        self.assertIn('DRY_RUN: "true"', text)
        self.assertIn('FORCE: "false"', text)

    def test_osp_to_ooc_preflight_has_no_write_secret_or_dispatch_gate(self):
        text = (WORKFLOWS / "mirror-osp-to-ooc.yml").read_text()
        self.assertIn("scripts/mirror_chain_push.py", text)
        self.assertNotIn("secrets.", text)
        self.assertNotIn("--write", text)
        planner = (ROOT / "scripts" / "mirror_chain_push.py").read_text()
        self.assertNotIn('"push"', planner)


if __name__ == "__main__":
    unittest.main()
