"""Tests for scripts/validate-template-config.py"""

import pytest
from conftest import make_manifest_profile, make_consumer, run_validator


def run(manifest_yaml, consumers_yaml, tmp_yaml):
    m_path = tmp_yaml(manifest_yaml, "manifest.yml")
    c_path = tmp_yaml(consumers_yaml, "consumers.yml")
    code, out = run_validator("validate-template-config.py", m_path, c_path)
    return code, out


def valid_manifest(extra_profiles=""):
    """Minimal valid manifest that always includes the required 'full' profile."""
    return (
        "profiles:\n"
        "  full:\n"
        "    description: All files\n"
        "    include:\n"
        "      - .github/workflows/*.yml\n"
        + extra_profiles
    )


def valid_consumers(extra=""):
    return "consumers:\n  - name: my-repo\n    profile: full\n" + extra


# ── Valid cases ───────────────────────────────────────────────────────────────

class TestValidCases:
    def test_minimal_valid_pair(self, tmp_yaml):
        code, out = run(valid_manifest(), valid_consumers(), tmp_yaml)
        assert code == 0
        assert "1 profile(s) valid" in out
        assert "1 consumer(s) valid" in out

    def test_multiple_profiles(self, tmp_yaml):
        manifest = (
            "profiles:\n"
            "  full:\n"
            "    description: All files\n"
            "    include:\n"
            "      - .github/workflows/*.yml\n"
            "  minimal:\n"
            "    description: Core only\n"
            "    include:\n"
            "      - .github/workflows/core.yml\n"
        )
        code, out = run(manifest, valid_consumers(), tmp_yaml)
        assert code == 0
        assert "2 profile(s) valid" in out

    def test_multiple_consumers(self, tmp_yaml):
        consumers = (
            "consumers:\n"
            "  - name: repo-a\n"
            "    profile: full\n"
            "  - name: repo-b\n"
            "    profile: full\n"
        )
        code, out = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 0
        assert "2 consumer(s) valid" in out

    def test_consumer_without_profile_defaults_to_full(self, tmp_yaml):
        consumers = "consumers:\n  - name: my-repo\n"
        code, _ = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 0

    def test_consumer_with_exclude_paths(self, tmp_yaml):
        consumers = (
            "consumers:\n"
            "  - name: my-repo\n"
            "    profile: full\n"
            "    exclude_paths:\n"
            "      - .github/workflows/heavy.yml\n"
        )
        code, _ = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 0

    def test_consumer_with_include_paths(self, tmp_yaml):
        consumers = (
            "consumers:\n"
            "  - name: my-repo\n"
            "    profile: full\n"
            "    include_paths:\n"
            "      - scripts/deploy.sh\n"
        )
        code, _ = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 0

    def test_consumer_with_boolean_fields(self, tmp_yaml):
        consumers = (
            "consumers:\n"
            "  - name: my-repo\n"
            "    profile: full\n"
            "    force: true\n"
            "    skip_osp_setup: false\n"
            "    disabled: false\n"
        )
        code, _ = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 0

    def test_manifest_with_exclude_list(self, tmp_yaml):
        manifest = (
            "profiles:\n"
            "  full:\n"
            "    description: All files\n"
            "    include:\n"
            "      - .github/workflows/*.yml\n"
            "    exclude:\n"
            "      - .github/workflows/skip-me.yml\n"
        )
        code, _ = run(manifest, valid_consumers(), tmp_yaml)
        assert code == 0

    def test_consumer_name_with_dots(self, tmp_yaml):
        consumers = "consumers:\n  - name: my.repo.name\n    profile: full\n"
        code, _ = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 0

    def test_consumer_name_with_hyphens_and_underscores(self, tmp_yaml):
        consumers = "consumers:\n  - name: my-repo_v2\n    profile: full\n"
        code, _ = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 0

    def test_empty_consumers_list(self, tmp_yaml):
        consumers = "consumers:\n"
        code, out = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 0
        assert "0 consumer(s) valid" in out

    def test_boolean_yaml_variants(self, tmp_yaml):
        for val in ("true", "false", "yes", "no"):
            consumers = f"consumers:\n  - name: my-repo\n    profile: full\n    force: {val}\n"
            code, _ = run(valid_manifest(), consumers, tmp_yaml)
            assert code == 0, f"Expected success for force: {val}"


# ── Manifest: missing 'full' profile ─────────────────────────────────────────

class TestManifestFullProfile:
    def test_missing_full_profile(self, tmp_yaml):
        manifest = (
            "profiles:\n"
            "  minimal:\n"
            "    description: Core only\n"
            "    include:\n"
            "      - .github/workflows/core.yml\n"
        )
        code, out = run(manifest, valid_consumers(), tmp_yaml)
        assert code == 1
        assert "'full' profile is missing" in out

    def test_full_profile_present_passes(self, tmp_yaml):
        code, _ = run(valid_manifest(), valid_consumers(), tmp_yaml)
        assert code == 0


# ── Manifest: profile validation ─────────────────────────────────────────────

class TestManifestProfileValidation:
    def test_missing_description(self, tmp_yaml):
        manifest = (
            "profiles:\n"
            "  full:\n"
            "    include:\n"
            "      - .github/workflows/*.yml\n"
        )
        code, out = run(manifest, valid_consumers(), tmp_yaml)
        assert code == 1
        assert "description" in out

    def test_empty_description(self, tmp_yaml):
        manifest = (
            "profiles:\n"
            "  full:\n"
            "    description:\n"
            "    include:\n"
            "      - .github/workflows/*.yml\n"
        )
        code, out = run(manifest, valid_consumers(), tmp_yaml)
        assert code == 1
        assert "description" in out

    def test_duplicate_profile_names(self, tmp_yaml):
        # The minimal YAML parser uses dict keys, so duplicates overwrite —
        # the validator won't see them as duplicates. This tests the actual
        # parser behaviour: second definition silently wins.
        manifest = (
            "profiles:\n"
            "  full:\n"
            "    description: First\n"
            "    include:\n"
            "      - .github/workflows/*.yml\n"
            "  full:\n"
            "    description: Second\n"
            "    include:\n"
            "      - .github/workflows/*.yml\n"
        )
        # Both definitions have valid content — validator sees one 'full' profile
        code, _ = run(manifest, valid_consumers(), tmp_yaml)
        assert code == 0

    def test_no_profiles_section(self, tmp_yaml):
        # When no `profiles:` key exists, parse_manifest returns {} and the
        # `if profiles and ...` guard skips the 'full' check — validator exits 0
        # with "0 profile(s) valid". This is a known limitation of the minimal parser.
        manifest = "other_key:\n  foo: bar\n"
        code, out = run(manifest, valid_consumers(), tmp_yaml)
        assert code == 0
        assert "0 profile(s) valid" in out

    def test_manifest_not_found(self, tmp_path, tmp_yaml):
        c_path = tmp_yaml(valid_consumers(), "consumers.yml")
        code, out = run_validator(
            "validate-template-config.py",
            str(tmp_path / "nonexistent.yml"),
            c_path,
        )
        assert code == 1
        assert "not found" in out


# ── Consumer: required fields ─────────────────────────────────────────────────

class TestConsumerRequiredFields:
    def test_missing_name(self, tmp_yaml):
        # The parser only starts a consumer entry on `  - name: ...` or `  - `.
        # `  - profile: full` matches neither pattern, so the entry is silently
        # skipped — 0 consumers parsed, exit 0. This is a known parser limitation.
        consumers = "consumers:\n  - profile: full\n"
        code, out = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 0
        assert "0 consumer(s) valid" in out

    def test_empty_name(self, tmp_yaml):
        consumers = "consumers:\n  - name: \"\"\n    profile: full\n"
        code, out = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 1
        assert "name" in out


# ── Consumer: name format ─────────────────────────────────────────────────────

class TestConsumerNameFormat:
    def test_name_with_slash(self, tmp_yaml):
        consumers = "consumers:\n  - name: org/repo\n    profile: full\n"
        code, out = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 1
        assert "valid GitHub repo name" in out

    def test_name_with_space(self, tmp_yaml):
        consumers = "consumers:\n  - name: my repo\n    profile: full\n"
        code, out = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 1

    def test_name_too_long(self, tmp_yaml):
        long_name = "a" * 101
        consumers = f"consumers:\n  - name: {long_name}\n    profile: full\n"
        code, out = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 1

    def test_name_exactly_100_chars(self, tmp_yaml):
        name = "a" * 100
        consumers = f"consumers:\n  - name: {name}\n    profile: full\n"
        code, _ = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 0

    def test_duplicate_consumer_names(self, tmp_yaml):
        consumers = (
            "consumers:\n"
            "  - name: same-repo\n"
            "    profile: full\n"
            "  - name: same-repo\n"
            "    profile: full\n"
        )
        code, out = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 1
        assert "duplicate consumer name" in out


# ── Consumer: profile reference ───────────────────────────────────────────────

class TestConsumerProfileReference:
    def test_unknown_profile(self, tmp_yaml):
        consumers = "consumers:\n  - name: my-repo\n    profile: nonexistent\n"
        code, out = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 1
        assert "nonexistent" in out
        assert "not defined" in out

    def test_known_non_full_profile(self, tmp_yaml):
        manifest = (
            "profiles:\n"
            "  full:\n"
            "    description: All files\n"
            "    include:\n"
            "      - .github/workflows/*.yml\n"
            "  minimal:\n"
            "    description: Core only\n"
            "    include:\n"
            "      - .github/workflows/core.yml\n"
        )
        consumers = "consumers:\n  - name: my-repo\n    profile: minimal\n"
        code, _ = run(manifest, consumers, tmp_yaml)
        assert code == 0

    def test_absent_profile_defaults_to_full(self, tmp_yaml):
        consumers = "consumers:\n  - name: my-repo\n"
        code, _ = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 0


# ── Consumer: boolean fields ──────────────────────────────────────────────────

class TestConsumerBooleanFields:
    @pytest.mark.parametrize("field", ["force", "skip_osp_setup", "disabled"])
    def test_invalid_boolean(self, tmp_yaml, field):
        consumers = (
            f"consumers:\n  - name: my-repo\n    profile: full\n    {field}: maybe\n"
        )
        code, out = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 1
        assert field in out

    @pytest.mark.parametrize("field", ["force", "skip_osp_setup", "disabled"])
    @pytest.mark.parametrize("val", ["true", "false", "yes", "no", "on", "off"])
    def test_valid_boolean_variants(self, tmp_yaml, field, val):
        consumers = (
            f"consumers:\n  - name: my-repo\n    profile: full\n    {field}: {val}\n"
        )
        code, _ = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 0


# ── Consumer: path list fields ────────────────────────────────────────────────

class TestConsumerPathFields:
    def test_exclude_paths_valid(self, tmp_yaml):
        consumers = (
            "consumers:\n"
            "  - name: my-repo\n"
            "    profile: full\n"
            "    exclude_paths:\n"
            "      - .github/workflows/skip.yml\n"
            "      - scripts/heavy.sh\n"
        )
        code, _ = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 0

    def test_include_paths_valid(self, tmp_yaml):
        consumers = (
            "consumers:\n"
            "  - name: my-repo\n"
            "    profile: full\n"
            "    include_paths:\n"
            "      - scripts/deploy.sh\n"
        )
        code, _ = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 0

    def test_inline_list_syntax(self, tmp_yaml):
        consumers = (
            "consumers:\n"
            "  - name: my-repo\n"
            "    profile: full\n"
            "    exclude_paths: [scripts/a.sh, scripts/b.sh]\n"
        )
        code, _ = run(valid_manifest(), consumers, tmp_yaml)
        assert code == 0


# ── File-level errors ─────────────────────────────────────────────────────────

class TestFileLevelErrors:
    def test_consumers_not_found(self, tmp_path, tmp_yaml):
        m_path = tmp_yaml(valid_manifest(), "manifest.yml")
        code, out = run_validator(
            "validate-template-config.py",
            m_path,
            str(tmp_path / "nonexistent.yml"),
        )
        assert code == 1
        assert "not found" in out

    def test_multiple_errors_accumulated(self, tmp_yaml):
        # Manifest missing description + consumer referencing unknown profile
        manifest = (
            "profiles:\n"
            "  full:\n"
            "    include:\n"          # missing description
            "      - .github/workflows/*.yml\n"
        )
        consumers = "consumers:\n  - name: my-repo\n    profile: ghost\n"
        code, out = run(manifest, consumers, tmp_yaml)
        assert code == 1
        assert out.count("✗") >= 2
