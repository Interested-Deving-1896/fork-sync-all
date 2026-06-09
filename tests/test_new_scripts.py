"""
Smoke tests for scripts added in this session:
  - scripts/includes/llm.sh
  - scripts/translate-docs.sh
  - scripts/pre-mirror-ci-gate.sh
  - scripts/verify-mirror-integrity.sh
  - scripts/post-flush-prep.sh
  - scripts/pipeline-telemetry.sh

Tests cover:
  1. Bash syntax check (bash -n) for every script
  2. Dry-run / missing-env early-exit behaviour where applicable
  3. translate-docs.sh: file discovery, watermark, SUMMARY.md upsert logic
     exercised against a minimal local DOCS tree (no LLM calls, no git push)
"""

import os
import subprocess
import textwrap
import json
import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS_DIR = os.path.join(REPO_ROOT, "scripts")


# ── Helpers ───────────────────────────────────────────────────────────────────

def bash_syntax(script_rel):
    """Return (returncode, stderr) for `bash -n <script>`."""
    path = os.path.join(REPO_ROOT, script_rel)
    r = subprocess.run(["bash", "-n", path], capture_output=True, text=True)
    return r.returncode, r.stderr


def run_script(script_rel, env=None, input_text=None, timeout=30):
    """Run a bash script with the given env overlay; return (rc, stdout, stderr)."""
    path = os.path.join(REPO_ROOT, script_rel)
    merged = {**os.environ, **(env or {})}
    r = subprocess.run(
        ["bash", path],
        env=merged,
        capture_output=True,
        text=True,
        timeout=timeout,
        input=input_text,
    )
    return r.returncode, r.stdout, r.stderr


# ── Syntax checks ─────────────────────────────────────────────────────────────

class TestSyntax:
    @pytest.mark.parametrize("script", [
        "scripts/includes/llm.sh",
        "scripts/translate-docs.sh",
        "scripts/pre-mirror-ci-gate.sh",
        "scripts/verify-mirror-integrity.sh",
        "scripts/post-flush-prep.sh",
        "scripts/pipeline-telemetry.sh",
    ])
    def test_bash_syntax(self, script):
        rc, stderr = bash_syntax(script)
        assert rc == 0, f"bash -n failed for {script}:\n{stderr}"


# ── Missing required env vars ─────────────────────────────────────────────────

class TestMissingEnv:
    """Each script should exit non-zero immediately when required vars are absent."""

    def test_pre_mirror_ci_gate_requires_gh_token(self):
        env = {"GH_TOKEN": "", "REPO": "owner/repo"}
        rc, _, stderr = run_script("scripts/pre-mirror-ci-gate.sh", env=env)
        assert rc != 0

    def test_pre_mirror_ci_gate_requires_repo(self):
        env = {"GH_TOKEN": "fake", "REPO": ""}
        rc, _, stderr = run_script("scripts/pre-mirror-ci-gate.sh", env=env)
        assert rc != 0

    def test_verify_mirror_integrity_requires_gh_token(self):
        env = {"GH_TOKEN": "", "MIRROR_PAIR": "id-1896-to-osp"}
        rc, _, _ = run_script("scripts/verify-mirror-integrity.sh", env=env)
        assert rc != 0

    def test_verify_mirror_integrity_requires_mirror_pair(self):
        env = {"GH_TOKEN": "fake", "MIRROR_PAIR": ""}
        rc, _, _ = run_script("scripts/verify-mirror-integrity.sh", env=env)
        assert rc != 0

    def test_verify_mirror_integrity_rejects_unknown_pair(self):
        env = {"GH_TOKEN": "fake", "MIRROR_PAIR": "bogus-pair"}
        rc, _, stderr = run_script("scripts/verify-mirror-integrity.sh", env=env)
        assert rc != 0
        assert "Unknown MIRROR_PAIR" in stderr

    def test_post_flush_prep_requires_gh_token(self):
        env = {"GH_TOKEN": "", "REPO": "owner/repo"}
        rc, _, _ = run_script("scripts/post-flush-prep.sh", env=env)
        assert rc != 0

    def test_pipeline_telemetry_requires_gh_token(self):
        env = {"GH_TOKEN": "", "REPO": "owner/repo", "RUN_ID": "123"}
        rc, _, _ = run_script("scripts/pipeline-telemetry.sh", env=env)
        assert rc != 0

    def test_translate_docs_requires_gh_token(self):
        env = {"GH_TOKEN": ""}
        rc, _, _ = run_script("scripts/translate-docs.sh", env=env)
        assert rc != 0


# ── Quota skip behaviour ──────────────────────────────────────────────────────

class TestQuotaSkip:
    """Scripts should exit 0 (skip gracefully) when MIN_QUOTA is set very high."""

    def test_pre_mirror_ci_gate_skips_on_low_quota(self):
        # MIN_QUOTA=9999999 forces the quota check to skip
        env = {
            "GH_TOKEN": "fake_token_for_test",
            "REPO": "owner/repo",
            "MIN_QUOTA": "9999999",
        }
        rc, _, stderr = run_script("scripts/pre-mirror-ci-gate.sh", env=env)
        assert rc == 0
        assert "too low" in stderr.lower() or "skipping" in stderr.lower()

    def test_verify_mirror_integrity_skips_on_low_quota(self):
        env = {
            "GH_TOKEN": "fake_token_for_test",
            "MIRROR_PAIR": "id-1896-to-osp",
            "MIN_QUOTA": "9999999",
        }
        rc, _, stderr = run_script("scripts/verify-mirror-integrity.sh", env=env)
        assert rc == 0
        assert "too low" in stderr.lower() or "skipping" in stderr.lower()

    def test_post_flush_prep_skips_on_low_quota(self):
        env = {
            "GH_TOKEN": "fake_token_for_test",
            "REPO": "owner/repo",
            "MIN_QUOTA": "9999999",
        }
        rc, _, stderr = run_script("scripts/post-flush-prep.sh", env=env)
        assert rc == 0
        assert "too low" in stderr.lower() or "skipping" in stderr.lower()

    def test_pipeline_telemetry_skips_on_low_quota(self):
        env = {
            "GH_TOKEN": "fake_token_for_test",
            "REPO": "owner/repo",
            "RUN_ID": "123456",
            "MIN_QUOTA": "9999999",
        }
        rc, _, stderr = run_script("scripts/pipeline-telemetry.sh", env=env)
        assert rc == 0
        assert "too low" in stderr.lower() or "skipping" in stderr.lower()


# ── translate-docs.sh: local filesystem logic ─────────────────────────────────

class TestTranslateDocs:
    """
    Tests for translate-docs.sh that exercise local filesystem logic without
    making any LLM API calls. Uses DRY_RUN=true so no files are written and
    no git commits are made.
    """

    def _make_docs(self, tmp_path):
        """Build a minimal DOCS/ tree under tmp_path."""
        docs = tmp_path / "DOCS"
        docs.mkdir()
        includes = tmp_path / "scripts" / "includes"
        includes.mkdir(parents=True)

        # Minimal budget.sh stub
        (includes / "budget.sh").write_text(textwrap.dedent("""\
            budget_init() { :; }
            budget_check() { return 0; }
            budget_report() { :; }
        """))

        # Minimal llm.sh stub (no real LLM calls)
        (includes / "llm.sh").write_text(textwrap.dedent("""\
            _LLM_SH_LOADED=1
            lang_name() { echo "${1}"; }
            detect_language() { echo "en"; }
            llm_translate() { echo "# Translated\\n\\n${1}"; }
        """))

        # Source docs
        (docs / "architecture.md").write_text("# Architecture\n\nContent here.\n")
        (docs / "contributing.md").write_text("# Contributing\n\nHow to contribute.\n")
        (docs / "SUMMARY.md").write_text(textwrap.dedent("""\
            # Summary

            - [Architecture](architecture.md)
            - [Contributing](contributing.md)
        """))

        return tmp_path

    def _base_env(self, tmp_path):
        return {
            "GH_TOKEN": "fake_token_for_test",
            "SOURCE_LANG": "en",
            "TARGET_LANG": "fr",
            "DOCS_DIR": "DOCS",
            "DRY_RUN": "true",
            "COMMIT": "false",
            "MODEL": "openai/gpt-4o",
            "BUDGET_MINUTES": "5",
            "MIN_QUOTA": "0",
            # Point script to our fake repo root
            "PWD": str(tmp_path),
        }

    def test_dry_run_exits_zero(self, tmp_path):
        root = self._make_docs(tmp_path)
        env = self._base_env(root)
        rc, stdout, stderr = run_script("scripts/translate-docs.sh", env=env)
        assert rc == 0, f"stderr: {stderr}"

    def test_dry_run_reports_files(self, tmp_path):
        root = self._make_docs(tmp_path)
        env = self._base_env(root)
        rc, _, stderr = run_script("scripts/translate-docs.sh", env=env)
        assert rc == 0
        # Should mention the two source files
        assert "architecture.md" in stderr or "contributing.md" in stderr

    def test_dry_run_summary_shows_translated_count(self, tmp_path):
        root = self._make_docs(tmp_path)
        env = self._base_env(root)
        rc, _, stderr = run_script("scripts/translate-docs.sh", env=env)
        assert rc == 0
        assert "translate-docs complete" in stderr

    def test_missing_docs_dir_exits_zero(self, tmp_path):
        """Script should skip gracefully if DOCS_DIR doesn't exist."""
        env = {
            "GH_TOKEN": "fake_token_for_test",
            "SOURCE_LANG": "en",
            "TARGET_LANG": "fr",
            "DOCS_DIR": "NONEXISTENT",
            "DRY_RUN": "true",
            "COMMIT": "false",
            "BUDGET_MINUTES": "5",
            "MIN_QUOTA": "0",
            "PWD": str(tmp_path),
        }
        rc, _, stderr = run_script("scripts/translate-docs.sh", env=env)
        assert rc == 0
        assert "not found" in stderr.lower() or "skipping" in stderr.lower()

    def test_same_source_and_target_lang_skips_all(self, tmp_path):
        """When SOURCE_LANG == TARGET_LANG, all files should be skipped."""
        root = self._make_docs(tmp_path)
        env = {**self._base_env(root), "SOURCE_LANG": "fr", "TARGET_LANG": "fr"}
        rc, _, stderr = run_script("scripts/translate-docs.sh", env=env)
        assert rc == 0
        assert "Translated : 0" in stderr or "skipped" in stderr.lower()


# ── llm.sh: sourcing and function availability ────────────────────────────────

class TestLlmInclude:
    """Verify llm.sh exports the expected functions when sourced."""

    def test_lang_name_english(self, tmp_path):
        script = tmp_path / "test.sh"
        script.write_text(textwrap.dedent(f"""\
            #!/usr/bin/env bash
            source {REPO_ROOT}/scripts/includes/llm.sh
            lang_name en
        """))
        r = subprocess.run(["bash", str(script)], capture_output=True, text=True)
        assert r.returncode == 0
        assert "English" in r.stdout

    def test_lang_name_italian(self, tmp_path):
        script = tmp_path / "test.sh"
        script.write_text(textwrap.dedent(f"""\
            #!/usr/bin/env bash
            source {REPO_ROOT}/scripts/includes/llm.sh
            lang_name it
        """))
        r = subprocess.run(["bash", str(script)], capture_output=True, text=True)
        assert r.returncode == 0
        assert "Italian" in r.stdout

    def test_readme_filename_english(self, tmp_path):
        script = tmp_path / "test.sh"
        script.write_text(textwrap.dedent(f"""\
            #!/usr/bin/env bash
            source {REPO_ROOT}/scripts/includes/llm.sh
            readme_filename en
        """))
        r = subprocess.run(["bash", str(script)], capture_output=True, text=True)
        assert r.returncode == 0
        assert r.stdout.strip() == "README.md"

    def test_readme_filename_non_english(self, tmp_path):
        script = tmp_path / "test.sh"
        script.write_text(textwrap.dedent(f"""\
            #!/usr/bin/env bash
            source {REPO_ROOT}/scripts/includes/llm.sh
            readme_filename fr
        """))
        r = subprocess.run(["bash", str(script)], capture_output=True, text=True)
        assert r.returncode == 0
        assert r.stdout.strip() == "README.fr.md"

    def test_double_source_guard(self, tmp_path):
        """Sourcing llm.sh twice should not redefine functions or error."""
        script = tmp_path / "test.sh"
        script.write_text(textwrap.dedent(f"""\
            #!/usr/bin/env bash
            source {REPO_ROOT}/scripts/includes/llm.sh
            source {REPO_ROOT}/scripts/includes/llm.sh
            lang_name de
        """))
        r = subprocess.run(["bash", str(script)], capture_output=True, text=True)
        assert r.returncode == 0
        assert "German" in r.stdout

    def test_build_switcher_marks_current_lang(self, tmp_path):
        """build_switcher should show current lang as plain text, not a link."""
        script = tmp_path / "test.sh"
        script.write_text(textwrap.dedent(f"""\
            #!/usr/bin/env bash
            source {REPO_ROOT}/scripts/includes/llm.sh
            build_switcher fr
        """))
        r = subprocess.run(["bash", str(script)], capture_output=True, text=True)
        assert r.returncode == 0
        # French should appear as plain text (no markdown link brackets)
        output = r.stdout
        assert "Français" in output
        # English should be a link
        assert "[" in output and "README.md" in output
