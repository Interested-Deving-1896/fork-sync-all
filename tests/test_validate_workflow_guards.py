"""Tests for scripts/validate-workflow-guards.py

The validator derives REPO_ROOT from __file__, so tests build a minimal fake
repo tree under tmp_path and run the script via a shim that overrides REPO_ROOT
before executing the validator logic.
"""

import os
import sys
import subprocess
import textwrap
import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT_PATH = os.path.join(REPO_ROOT, "scripts", "validate-workflow-guards.py")


# ── Fake repo builder ─────────────────────────────────────────────────────────

class FakeRepo:
    """Builds a minimal fake repo tree under a tmp_path directory."""

    def __init__(self, root):
        self.root = root
        self.workflows_dir = root / ".github" / "workflows"
        self.scripts_dir = root / "scripts"
        self.config_dir = root / "config"
        self.workflows_dir.mkdir(parents=True, exist_ok=True)
        self.scripts_dir.mkdir(parents=True, exist_ok=True)
        self.config_dir.mkdir(parents=True, exist_ok=True)

    def add_workflow(self, name, content):
        (self.workflows_dir / name).write_text(textwrap.dedent(content))

    def add_script(self, name, content="#!/bin/bash\necho ok\n"):
        (self.scripts_dir / name).write_text(content)

    def set_gitlab_ci(self, content):
        (self.root / ".gitlab-ci.yml").write_text(textwrap.dedent(content))

    def set_sync_manifest(self, content):
        (self.config_dir / "workflow-sync.yml").write_text(textwrap.dedent(content))

    def run(self):
        """Run the validator against this fake repo; return (exit_code, output)."""
        shim = textwrap.dedent(f"""\
            import sys, os
            # Override REPO_ROOT before the validator computes its paths
            import importlib.util, types

            fake_root = {str(self.root)!r}
            script_path = {SCRIPT_PATH!r}

            with open(script_path) as f:
                src = f.read()

            # Patch the REPO_ROOT line
            src = src.replace(
                "REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))",
                f"REPO_ROOT = {str(self.root)!r}",
            )

            exec(compile(src, script_path, "exec"), {{"__file__": script_path}})
        """)
        result = subprocess.run(
            [sys.executable, "-c", shim],
            capture_output=True,
            text=True,
        )
        return result.returncode, result.stdout + result.stderr


@pytest.fixture
def repo(tmp_path):
    return FakeRepo(tmp_path)


# ── Minimal valid repo (no workflows, no gitlab-ci, no sync manifest) ─────────

class TestMinimalRepo:
    def test_empty_repo_passes(self, repo):
        # No workflows, no .gitlab-ci.yml, no sync manifest — all checks skip
        code, out = repo.run()
        assert code == 0
        assert "all checks passed" in out

    def test_workflow_without_rate_limit_input_passes(self, repo):
        repo.add_workflow("ci.yml", """\
            on: [push]
            jobs:
              build:
                runs-on: ubuntu-latest
                steps:
                  - run: echo hi
        """)
        code, _ = repo.run()
        assert code == 0

    def test_no_gitlab_ci_warns_not_errors(self, repo):
        code, out = repo.run()
        assert code == 0
        # Warning may or may not appear depending on whether .gitlab-ci.yml exists


# ── Check 1: rate_limit_rerun guard ──────────────────────────────────────────

class TestRateLimitRerunGuard:
    def _workflow_with_input(self, guard_line=""):
        return textwrap.dedent(f"""\
            on:
              workflow_dispatch:
                inputs:
                  rate_limit_rerun:
                    description: Skip if already retried
                    type: boolean
            jobs:
              run:
                runs-on: ubuntu-latest
                {guard_line}
                steps:
                  - run: echo hi
        """)

    def test_input_declared_with_guard_passes(self, repo):
        content = self._workflow_with_input(
            "if: inputs.rate_limit_rerun != 'true'"
        )
        repo.add_workflow("sync.yml", content)
        code, _ = repo.run()
        assert code == 0

    def test_input_declared_without_guard_fails(self, repo):
        content = self._workflow_with_input()
        repo.add_workflow("sync.yml", content)
        code, out = repo.run()
        assert code == 1
        assert "[guard]" in out
        assert "sync.yml" in out

    def test_guard_with_double_quotes_accepted(self, repo):
        content = self._workflow_with_input(
            'if: inputs.rate_limit_rerun != "true"'
        )
        repo.add_workflow("sync.yml", content)
        code, _ = repo.run()
        assert code == 0

    def test_guard_in_compound_condition_accepted(self, repo):
        content = self._workflow_with_input(
            "if: github.event_name == 'push' && inputs.rate_limit_rerun != 'true'"
        )
        repo.add_workflow("sync.yml", content)
        code, _ = repo.run()
        assert code == 0

    def test_rate_limit_rerun_in_step_name_not_flagged(self, repo):
        # The input must be at 6+ spaces indent to be detected
        content = textwrap.dedent("""\
            on: [push]
            jobs:
              run:
                runs-on: ubuntu-latest
                steps:
                  - name: rate_limit_rerun check
                    run: echo hi
        """)
        repo.add_workflow("ci.yml", content)
        code, _ = repo.run()
        assert code == 0

    def test_multiple_workflows_both_missing_guard(self, repo):
        wf = self._workflow_with_input()
        repo.add_workflow("sync-a.yml", wf)
        repo.add_workflow("sync-b.yml", wf)
        code, out = repo.run()
        assert code == 1
        assert out.count("[guard]") == 2

    def test_one_guarded_one_not(self, repo):
        repo.add_workflow("good.yml", self._workflow_with_input(
            "if: inputs.rate_limit_rerun != 'true'"
        ))
        repo.add_workflow("bad.yml", self._workflow_with_input())
        code, out = repo.run()
        assert code == 1
        assert "bad.yml" in out
        assert "good.yml" not in out


# ── Check 2: .gitlab-ci.yml script existence ─────────────────────────────────

class TestGitlabCiScriptExistence:
    def test_referenced_script_exists(self, repo):
        repo.add_script("sync.sh")
        repo.set_gitlab_ci("""\
            sync-job:
              script:
                - bash scripts/sync.sh
        """)
        code, _ = repo.run()
        assert code == 0

    def test_referenced_script_missing(self, repo):
        repo.set_gitlab_ci("""\
            sync-job:
              script:
                - bash scripts/missing.sh
        """)
        code, out = repo.run()
        assert code == 1
        assert "[gitlab-ci]" in out
        assert "missing.sh" in out

    def test_multiple_scripts_one_missing(self, repo):
        repo.add_script("exists.sh")
        repo.set_gitlab_ci("""\
            job-a:
              script:
                - bash scripts/exists.sh
            job-b:
              script:
                - bash scripts/gone.sh
        """)
        code, out = repo.run()
        assert code == 1
        assert "gone.sh" in out
        assert "exists.sh" not in out

    def test_no_bash_scripts_reference_passes(self, repo):
        repo.set_gitlab_ci("""\
            job:
              script:
                - echo hello
                - python3 scripts/helper.py
        """)
        code, _ = repo.run()
        assert code == 0

    def test_no_gitlab_ci_skips_check(self, repo):
        # No .gitlab-ci.yml — check 2 is skipped with a warning
        code, out = repo.run()
        assert code == 0


# ── Check 3: workflow-sync.yml manifest consistency ──────────────────────────

class TestSyncManifestConsistency:
    def _base_manifest(self, paired="", github_only="", gitlab_only=""):
        parts = []
        if paired:
            parts.append(f"paired:\n{paired}")
        if github_only:
            parts.append(f"github_only:\n{github_only}")
        if gitlab_only:
            parts.append(f"gitlab_only:\n{gitlab_only}")
        return "\n".join(parts) + "\n"

    def test_valid_paired_entry(self, repo):
        repo.add_workflow("sync.yml", "on: [push]\njobs:\n  run:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n")
        repo.add_script("sync.sh")
        repo.set_gitlab_ci("sync-job:\n  script:\n    - bash scripts/sync.sh\n")
        manifest = (
            "paired:\n"
            "  - name: sync\n"
            "    scripts:\n"
            "      - sync.sh\n"
            "    github:\n"
            "      workflow_file: sync.yml\n"
            "    gitlab:\n"
            "      job: sync-job\n"
        )
        repo.set_sync_manifest(manifest)
        code, _ = repo.run()
        assert code == 0

    def test_paired_missing_github_workflow(self, repo):
        repo.set_gitlab_ci("sync-job:\n  script:\n    - echo hi\n")
        manifest = (
            "paired:\n"
            "  - name: sync\n"
            "    github:\n"
            "      workflow_file: nonexistent.yml\n"
            "    gitlab:\n"
            "      job: sync-job\n"
        )
        repo.set_sync_manifest(manifest)
        code, out = repo.run()
        assert code == 1
        assert "[sync-manifest]" in out
        assert "nonexistent.yml" in out

    def test_paired_missing_gitlab_job(self, repo):
        repo.add_workflow("sync.yml", "on: [push]\njobs:\n  run:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n")
        repo.set_gitlab_ci("real-job:\n  script:\n    - echo hi\n")
        manifest = (
            "paired:\n"
            "  - name: sync\n"
            "    github:\n"
            "      workflow_file: sync.yml\n"
            "    gitlab:\n"
            "      job: ghost-job\n"
        )
        repo.set_sync_manifest(manifest)
        code, out = repo.run()
        assert code == 1
        assert "ghost-job" in out

    def test_paired_missing_script(self, repo):
        repo.add_workflow("sync.yml", "on: [push]\njobs:\n  run:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n")
        repo.set_gitlab_ci("sync-job:\n  script:\n    - echo hi\n")
        manifest = (
            "paired:\n"
            "  - name: sync\n"
            "    scripts:\n"
            "      - missing.sh\n"
            "    github:\n"
            "      workflow_file: sync.yml\n"
            "    gitlab:\n"
            "      job: sync-job\n"
        )
        repo.set_sync_manifest(manifest)
        code, out = repo.run()
        assert code == 1
        assert "missing.sh" in out

    def test_github_only_workflow_exists(self, repo):
        repo.add_workflow("ci.yml", "on: [push]\njobs:\n  run:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n")
        manifest = "github_only:\n  - workflow_file: ci.yml\n"
        repo.set_sync_manifest(manifest)
        code, _ = repo.run()
        assert code == 0

    def test_github_only_workflow_missing(self, repo):
        manifest = "github_only:\n  - workflow_file: ghost.yml\n"
        repo.set_sync_manifest(manifest)
        code, out = repo.run()
        assert code == 1
        assert "ghost.yml" in out

    def test_gitlab_only_job_exists(self, repo):
        repo.set_gitlab_ci("special-job:\n  script:\n    - echo hi\n")
        manifest = "gitlab_only:\n  - job: special-job\n"
        repo.set_sync_manifest(manifest)
        code, _ = repo.run()
        assert code == 0

    def test_gitlab_only_job_missing(self, repo):
        repo.set_gitlab_ci("real-job:\n  script:\n    - echo hi\n")
        manifest = "gitlab_only:\n  - job: ghost-job\n"
        repo.set_sync_manifest(manifest)
        code, out = repo.run()
        assert code == 1
        assert "ghost-job" in out

    def test_no_sync_manifest_skips_check(self, repo):
        # No workflow-sync.yml — check 3 is skipped with a warning
        code, out = repo.run()
        assert code == 0

    def test_unlisted_workflow_generates_warning_not_error(self, repo):
        # A workflow not in the manifest generates a warning, not an error
        repo.add_workflow("unlisted.yml", "on: [push]\njobs:\n  run:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n")
        manifest = "github_only:\n  - workflow_file: other.yml\n"
        # other.yml doesn't exist → error; unlisted.yml → warning
        # We just verify unlisted.yml warning doesn't cause exit 1 on its own
        repo.add_workflow("other.yml", "on: [push]\njobs:\n  run:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n")
        manifest = "github_only:\n  - workflow_file: other.yml\n"
        repo.set_sync_manifest(manifest)
        code, out = repo.run()
        assert code == 0
        assert "unlisted.yml" in out  # warning about uncovered workflow


# ── Combined checks ───────────────────────────────────────────────────────────

class TestCombinedChecks:
    def test_all_three_checks_fail_accumulate(self, repo):
        # Check 1: workflow with input but no guard
        repo.add_workflow("sync.yml", textwrap.dedent("""\
            on:
              workflow_dispatch:
                inputs:
                  rate_limit_rerun:
                    type: boolean
            jobs:
              run:
                runs-on: ubuntu-latest
                steps:
                  - run: echo hi
        """))
        # Check 2: missing script in gitlab-ci
        repo.set_gitlab_ci("job:\n  script:\n    - bash scripts/gone.sh\n")
        # Check 3: missing workflow in sync manifest
        manifest = "github_only:\n  - workflow_file: ghost.yml\n"
        repo.set_sync_manifest(manifest)

        code, out = repo.run()
        assert code == 1
        assert out.count("✗") >= 3

    def test_success_message_on_all_pass(self, repo):
        repo.add_workflow("ci.yml", "on: [push]\njobs:\n  run:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n")
        repo.add_script("sync.sh")
        repo.set_gitlab_ci("sync-job:\n  script:\n    - bash scripts/sync.sh\n")
        manifest = (
            "paired:\n"
            "  - name: sync\n"
            "    scripts:\n"
            "      - sync.sh\n"
            "    github:\n"
            "      workflow_file: ci.yml\n"
            "    gitlab:\n"
            "      job: sync-job\n"
        )
        repo.set_sync_manifest(manifest)
        code, out = repo.run()
        assert code == 0
        assert "all checks passed" in out
