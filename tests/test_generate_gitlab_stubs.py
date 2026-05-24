"""Tests for scripts/generate-gitlab-stubs.py

The script derives REPO_ROOT from __file__, so tests build a minimal fake
repo tree under tmp_path and run the script via a shim that overrides REPO_ROOT.

Key behaviours under test:
  - Paired job in sync → ✓
  - Paired job missing from .gitlab-ci.yml → ✗ job not found
  - Script drift (expected script absent from job block) → ⚠ drift
  - Cadence drift (CADENCE value mismatch) → ⚠ drift
  - Push/trigger cadence checks
  - --check flag: exits 1 on drift, exits 0 without flag
  - Missing SYNC_MANIFEST or GITLAB_CI → exits 1
"""

import os
import sys
import subprocess
import textwrap
import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT_PATH = os.path.join(REPO_ROOT, "scripts", "generate-gitlab-stubs.py")


# ── Fake repo builder ─────────────────────────────────────────────────────────

class FakeRepo:
    def __init__(self, root):
        self.root = root
        self.scripts_dir = root / "scripts"
        self.config_dir = root / "config"
        self.scripts_dir.mkdir(parents=True, exist_ok=True)
        self.config_dir.mkdir(parents=True, exist_ok=True)

    def set_gitlab_ci(self, content):
        (self.root / ".gitlab-ci.yml").write_text(textwrap.dedent(content))

    def set_sync_manifest(self, content):
        (self.config_dir / "workflow-sync.yml").write_text(textwrap.dedent(content))

    def run(self, *extra_args):
        """Run the script against this fake repo; return (exit_code, output)."""
        shim = textwrap.dedent(f"""\
            import sys, os
            fake_root = {str(self.root)!r}
            script_path = {SCRIPT_PATH!r}
            extra_args = {list(extra_args)!r}

            with open(script_path) as f:
                src = f.read()

            src = src.replace(
                "REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))",
                f"REPO_ROOT = {{fake_root!r}}",
            )
            # Inject extra args into sys.argv
            sys.argv = [script_path] + extra_args

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


# ── Helpers to build common YAML fragments ────────────────────────────────────

def paired_entry(name, scripts=None, workflow_file="ci.yml", job="ci-job",
                 cadence=None, gl_script=None):
    lines = [f"  - name: {name}"]
    if scripts:
        lines.append("    scripts:")
        for s in scripts:
            lines.append(f"      - {s}")
    lines += [
        "    github:",
        f"      workflow_file: {workflow_file}",
        "    gitlab:",
        f"      job: {job}",
    ]
    if cadence:
        lines.append(f"      cadence: {cadence}")
    if gl_script:
        lines.append(f"      script: {gl_script}")
    return "\n".join(lines)


def gitlab_job(name, scripts=None, cadence=None, push=False, trigger=False):
    lines = [f"{name}:"]
    if scripts or cadence or push or trigger:
        lines.append("  rules:")
        if push:
            lines.append('    - if: $CI_PIPELINE_SOURCE == "push"')
        if trigger:
            lines.append('    - if: $CI_PIPELINE_SOURCE == "trigger"')
        if cadence:
            lines.append(f'    - if: $CADENCE == "{cadence}"')
    lines.append("  script:")
    for s in (scripts or []):
        lines.append(f"    - bash scripts/{s}")
    if not scripts:
        lines.append("    - echo hi")
    return "\n".join(lines) + "\n"


# ── Missing required files ────────────────────────────────────────────────────

class TestMissingFiles:
    def test_missing_sync_manifest(self, repo):
        repo.set_gitlab_ci("job:\n  script:\n    - echo hi\n")
        # No sync manifest
        code, out = repo.run()
        assert code == 1
        assert "not found" in out

    def test_missing_gitlab_ci(self, repo):
        repo.set_sync_manifest("paired:\n  - name: test\n    github:\n      workflow_file: ci.yml\n    gitlab:\n      job: ci-job\n")
        # No .gitlab-ci.yml
        code, out = repo.run()
        assert code == 1
        assert "not found" in out

    def test_both_missing(self, repo):
        code, out = repo.run()
        assert code == 1
        assert "not found" in out


# ── Job presence ──────────────────────────────────────────────────────────────

class TestJobPresence:
    def test_job_found_no_drift(self, repo):
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", scripts=["sync.sh"], job="sync-job") + "\n"
        )
        repo.set_gitlab_ci(gitlab_job("sync-job", scripts=["sync.sh"]))
        code, out = repo.run()
        assert code == 0
        assert "✓" in out

    def test_job_not_found_in_gitlab_ci(self, repo):
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", job="ghost-job") + "\n"
        )
        repo.set_gitlab_ci("real-job:\n  script:\n    - echo hi\n")
        code, out = repo.run()
        # Without --check, exits 0 even with drift
        assert code == 0
        assert "not found" in out

    def test_job_not_found_check_mode_exits_1(self, repo):
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", job="ghost-job") + "\n"
        )
        repo.set_gitlab_ci("real-job:\n  script:\n    - echo hi\n")
        code, out = repo.run("--check")
        assert code == 1
        assert "ghost-job" in out

    def test_empty_paired_list(self, repo):
        repo.set_sync_manifest("paired:\n")
        repo.set_gitlab_ci("job:\n  script:\n    - echo hi\n")
        code, out = repo.run()
        assert code == 0
        assert "0 paired jobs" in out or "0 ok" in out


# ── Script drift ──────────────────────────────────────────────────────────────

class TestScriptDrift:
    def test_expected_script_present(self, repo):
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", scripts=["sync.sh"], job="sync-job") + "\n"
        )
        repo.set_gitlab_ci(gitlab_job("sync-job", scripts=["sync.sh"]))
        code, out = repo.run("--check")
        assert code == 0

    def test_expected_script_absent(self, repo):
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", scripts=["sync.sh"], job="sync-job") + "\n"
        )
        repo.set_gitlab_ci(gitlab_job("sync-job", scripts=["other.sh"]))
        code, out = repo.run("--check")
        assert code == 1
        assert "drift" in out.lower()
        assert "sync.sh" in out

    def test_extra_scripts_in_job_not_flagged(self, repo):
        # Job has more scripts than manifest expects — not an error
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", scripts=["sync.sh"], job="sync-job") + "\n"
        )
        repo.set_gitlab_ci(gitlab_job("sync-job", scripts=["sync.sh", "extra.sh"]))
        code, out = repo.run("--check")
        assert code == 0

    def test_multiple_expected_scripts_all_present(self, repo):
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", scripts=["a.sh", "b.sh"], job="sync-job") + "\n"
        )
        ci = (
            "sync-job:\n"
            "  script:\n"
            "    - bash scripts/a.sh\n"
            "    - bash scripts/b.sh\n"
        )
        repo.set_gitlab_ci(ci)
        code, _ = repo.run("--check")
        assert code == 0

    def test_multiple_expected_scripts_one_missing(self, repo):
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", scripts=["a.sh", "b.sh"], job="sync-job") + "\n"
        )
        ci = "sync-job:\n  script:\n    - bash scripts/a.sh\n"
        repo.set_gitlab_ci(ci)
        code, out = repo.run("--check")
        assert code == 1
        assert "b.sh" in out

    def test_gitlab_script_override(self, repo):
        # gitlab.script overrides the shared scripts list
        repo.set_sync_manifest(
            "paired:\n"
            + paired_entry("sync", scripts=["shared.sh"], job="sync-job", gl_script="wrapper.sh")
            + "\n"
        )
        # Job uses wrapper.sh, not shared.sh — should be in sync
        ci = "sync-job:\n  script:\n    - bash scripts/wrapper.sh\n"
        repo.set_gitlab_ci(ci)
        code, out = repo.run("--check")
        assert code == 0

    def test_gitlab_script_override_missing(self, repo):
        repo.set_sync_manifest(
            "paired:\n"
            + paired_entry("sync", scripts=["shared.sh"], job="sync-job", gl_script="wrapper.sh")
            + "\n"
        )
        # Job uses shared.sh, not wrapper.sh — drift
        ci = "sync-job:\n  script:\n    - bash scripts/shared.sh\n"
        repo.set_gitlab_ci(ci)
        code, out = repo.run("--check")
        assert code == 1
        assert "wrapper.sh" in out


# ── Cadence drift ─────────────────────────────────────────────────────────────

class TestCadenceDrift:
    def test_cadence_matches(self, repo):
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", job="sync-job", cadence="daily") + "\n"
        )
        repo.set_gitlab_ci(gitlab_job("sync-job", cadence="daily"))
        code, _ = repo.run("--check")
        assert code == 0

    def test_cadence_mismatch(self, repo):
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", job="sync-job", cadence="daily") + "\n"
        )
        repo.set_gitlab_ci(gitlab_job("sync-job", cadence="weekly"))
        code, out = repo.run("--check")
        assert code == 1
        assert "cadence" in out
        assert "daily" in out

    def test_cadence_missing_from_job(self, repo):
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", job="sync-job", cadence="hourly") + "\n"
        )
        repo.set_gitlab_ci(gitlab_job("sync-job"))  # no cadence rule
        code, out = repo.run("--check")
        assert code == 1
        assert "cadence" in out

    def test_push_cadence_present(self, repo):
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", job="sync-job", cadence="push") + "\n"
        )
        repo.set_gitlab_ci(gitlab_job("sync-job", push=True))
        code, _ = repo.run("--check")
        assert code == 0

    def test_push_cadence_absent(self, repo):
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", job="sync-job", cadence="push") + "\n"
        )
        repo.set_gitlab_ci(gitlab_job("sync-job"))  # no push rule
        code, out = repo.run("--check")
        assert code == 1
        assert "push" in out

    def test_trigger_cadence_present(self, repo):
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", job="sync-job", cadence="trigger") + "\n"
        )
        repo.set_gitlab_ci(gitlab_job("sync-job", trigger=True))
        code, _ = repo.run("--check")
        assert code == 0

    def test_trigger_cadence_absent(self, repo):
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", job="sync-job", cadence="trigger") + "\n"
        )
        repo.set_gitlab_ci(gitlab_job("sync-job"))
        code, out = repo.run("--check")
        assert code == 1
        assert "trigger" in out

    def test_manual_cadence_not_checked(self, repo):
        # cadence: manual is explicitly skipped in drift detection
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", job="sync-job", cadence="manual") + "\n"
        )
        repo.set_gitlab_ci(gitlab_job("sync-job"))  # no cadence rule — fine for manual
        code, _ = repo.run("--check")
        assert code == 0

    def test_no_cadence_in_manifest_not_checked(self, repo):
        # No cadence field in manifest — cadence check is skipped
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", job="sync-job") + "\n"
        )
        repo.set_gitlab_ci(gitlab_job("sync-job", cadence="daily"))
        code, _ = repo.run("--check")
        assert code == 0


# ── --check flag behaviour ────────────────────────────────────────────────────

class TestCheckFlag:
    def test_no_drift_check_mode_exits_0(self, repo):
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", scripts=["sync.sh"], job="sync-job") + "\n"
        )
        repo.set_gitlab_ci(gitlab_job("sync-job", scripts=["sync.sh"]))
        code, _ = repo.run("--check")
        assert code == 0

    def test_drift_without_check_flag_exits_0(self, repo):
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", scripts=["sync.sh"], job="sync-job") + "\n"
        )
        repo.set_gitlab_ci(gitlab_job("sync-job", scripts=["other.sh"]))
        code, out = repo.run()  # no --check
        assert code == 0
        assert "drift" in out.lower()

    def test_drift_with_check_flag_exits_1(self, repo):
        repo.set_sync_manifest(
            "paired:\n" + paired_entry("sync", scripts=["sync.sh"], job="sync-job") + "\n"
        )
        repo.set_gitlab_ci(gitlab_job("sync-job", scripts=["other.sh"]))
        code, _ = repo.run("--check")
        assert code == 1


# ── Multiple paired jobs ──────────────────────────────────────────────────────

class TestMultiplePairedJobs:
    def test_all_in_sync(self, repo):
        manifest = (
            "paired:\n"
            + paired_entry("job-a", scripts=["a.sh"], job="job-a") + "\n"
            + paired_entry("job-b", scripts=["b.sh"], job="job-b") + "\n"
        )
        repo.set_sync_manifest(manifest)
        ci = gitlab_job("job-a", scripts=["a.sh"]) + gitlab_job("job-b", scripts=["b.sh"])
        repo.set_gitlab_ci(ci)
        code, out = repo.run("--check")
        assert code == 0
        assert "2 ok" in out

    def test_one_drifted_one_ok(self, repo):
        manifest = (
            "paired:\n"
            + paired_entry("job-a", scripts=["a.sh"], job="job-a") + "\n"
            + paired_entry("job-b", scripts=["b.sh"], job="job-b") + "\n"
        )
        repo.set_sync_manifest(manifest)
        ci = gitlab_job("job-a", scripts=["a.sh"]) + gitlab_job("job-b", scripts=["wrong.sh"])
        repo.set_gitlab_ci(ci)
        code, out = repo.run("--check")
        assert code == 1
        assert "1 ok" in out
        assert "1 drifted" in out

    def test_summary_counts_missing_separately(self, repo):
        manifest = (
            "paired:\n"
            + paired_entry("job-a", scripts=["a.sh"], job="job-a") + "\n"
            + paired_entry("job-b", scripts=["b.sh"], job="ghost-job") + "\n"
        )
        repo.set_sync_manifest(manifest)
        ci = gitlab_job("job-a", scripts=["a.sh"])
        repo.set_gitlab_ci(ci)
        code, out = repo.run("--check")
        assert code == 1
        assert "1 missing" in out

    def test_output_includes_job_table(self, repo):
        manifest = "paired:\n" + paired_entry("sync", scripts=["sync.sh"], job="sync-job") + "\n"
        repo.set_sync_manifest(manifest)
        repo.set_gitlab_ci(gitlab_job("sync-job", scripts=["sync.sh"]))
        _, out = repo.run()
        assert "sync-job" in out
        assert "Job" in out  # table header
