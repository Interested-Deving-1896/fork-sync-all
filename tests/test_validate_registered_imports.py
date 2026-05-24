"""Tests for scripts/validate-registered-imports.py"""

import json
import pytest
from conftest import make_import_entry, run_validator


def run(data, tmp_json):
    path = tmp_json(data)
    code, out = run_validator("validate-registered-imports.py", path)
    return code, out


# ── Valid cases ───────────────────────────────────────────────────────────────

class TestValidCases:
    def test_single_valid_github_entry(self, tmp_json):
        code, out = run([make_import_entry(
            source_url="https://github.com/foo/bar",
            platform="github",
            target_name="bar",
        )], tmp_json)
        assert code == 0
        assert "1 entry" in out

    def test_single_valid_gitlab_entry(self, tmp_json):
        code, out = run([make_import_entry()], tmp_json)
        assert code == 0

    def test_single_valid_bitbucket_entry(self, tmp_json):
        code, out = run([make_import_entry(
            source_url="https://bitbucket.org/foo/bar",
            platform="bitbucket",
        )], tmp_json)
        assert code == 0

    def test_single_valid_gitea_entry(self, tmp_json):
        # gitea is self-hosted — any host is valid
        code, out = run([make_import_entry(
            source_url="https://gitea.example.com/foo/bar",
            platform="gitea",
        )], tmp_json)
        assert code == 0

    def test_multiple_valid_entries(self, tmp_json):
        entries = [
            make_import_entry(target_name="repo-a", source_url="https://gitlab.com/foo/a"),
            make_import_entry(target_name="repo-b", source_url="https://gitlab.com/foo/b"),
            make_import_entry(target_name="repo-c", source_url="https://gitlab.com/foo/c"),
        ]
        code, out = run(entries, tmp_json)
        assert code == 0
        assert "3 entry" in out

    def test_empty_file(self, tmp_path):
        p = tmp_path / "empty.json"
        p.write_text("")
        code, out = run_validator("validate-registered-imports.py", str(p))
        assert code == 0
        assert "empty" in out.lower()

    def test_empty_array(self, tmp_json):
        code, out = run([], tmp_json)
        assert code == 0

    def test_iso8601_with_offset(self, tmp_json):
        code, _ = run([make_import_entry(added="2026-01-01T12:00:00+05:30")], tmp_json)
        assert code == 0

    def test_iso8601_with_fractional_seconds(self, tmp_json):
        code, _ = run([make_import_entry(added="2026-01-01T12:00:00.123Z")], tmp_json)
        assert code == 0

    def test_target_name_with_dots_and_hyphens(self, tmp_json):
        code, _ = run([make_import_entry(target_name="my.repo-name_v2")], tmp_json)
        assert code == 0


# ── Missing required fields ───────────────────────────────────────────────────

class TestMissingFields:
    @pytest.mark.parametrize("field", ["source_url", "target_name", "platform", "added"])
    def test_missing_required_field(self, tmp_json, field):
        entry = make_import_entry()
        del entry[field]
        code, out = run([entry], tmp_json)
        assert code == 1
        assert field in out

    def test_empty_source_url(self, tmp_json):
        code, out = run([make_import_entry(source_url="")], tmp_json)
        assert code == 1
        assert "source_url" in out

    def test_empty_target_name(self, tmp_json):
        code, out = run([make_import_entry(target_name="")], tmp_json)
        assert code == 1
        assert "target_name" in out


# ── URL validation ────────────────────────────────────────────────────────────

class TestUrlValidation:
    def test_http_not_https(self, tmp_json):
        code, out = run([make_import_entry(source_url="http://gitlab.com/foo/bar")], tmp_json)
        assert code == 1
        assert "https" in out

    def test_ssh_url_rejected(self, tmp_json):
        code, out = run([make_import_entry(source_url="git@gitlab.com:foo/bar.git")], tmp_json)
        assert code == 1

    def test_platform_host_mismatch_github_on_gitlab(self, tmp_json):
        code, out = run([make_import_entry(
            source_url="https://github.com/foo/bar",
            platform="gitlab",
        )], tmp_json)
        assert code == 1
        assert "gitlab.com" in out

    def test_platform_host_mismatch_gitlab_on_bitbucket(self, tmp_json):
        code, out = run([make_import_entry(
            source_url="https://gitlab.com/foo/bar",
            platform="bitbucket",
        )], tmp_json)
        assert code == 1

    def test_gitea_any_host_accepted(self, tmp_json):
        # gitea is self-hosted — no host restriction
        code, _ = run([make_import_entry(
            source_url="https://my-gitea.internal/foo/bar",
            platform="gitea",
        )], tmp_json)
        assert code == 0


# ── Platform validation ───────────────────────────────────────────────────────

class TestPlatformValidation:
    def test_unknown_platform(self, tmp_json):
        code, out = run([make_import_entry(platform="sourcehut")], tmp_json)
        assert code == 1
        assert "platform" in out

    def test_empty_platform(self, tmp_json):
        code, out = run([make_import_entry(platform="")], tmp_json)
        assert code == 1

    @pytest.mark.parametrize("platform", ["github", "gitlab", "bitbucket", "gitea"])
    def test_all_valid_platforms(self, tmp_json, platform):
        hosts = {
            "github": "https://github.com/foo/bar",
            "gitlab": "https://gitlab.com/foo/bar",
            "bitbucket": "https://bitbucket.org/foo/bar",
            "gitea": "https://gitea.example.com/foo/bar",
        }
        code, _ = run([make_import_entry(
            source_url=hosts[platform], platform=platform
        )], tmp_json)
        assert code == 0


# ── Target name validation ────────────────────────────────────────────────────

class TestTargetNameValidation:
    def test_slash_in_name(self, tmp_json):
        code, out = run([make_import_entry(target_name="org/repo")], tmp_json)
        assert code == 1

    def test_space_in_name(self, tmp_json):
        code, out = run([make_import_entry(target_name="my repo")], tmp_json)
        assert code == 1

    def test_name_too_long(self, tmp_json):
        code, out = run([make_import_entry(target_name="a" * 101)], tmp_json)
        assert code == 1

    def test_name_exactly_100_chars(self, tmp_json):
        code, _ = run([make_import_entry(target_name="a" * 100)], tmp_json)
        assert code == 0


# ── Timestamp validation ──────────────────────────────────────────────────────

class TestTimestampValidation:
    def test_invalid_timestamp_plain_date(self, tmp_json):
        code, out = run([make_import_entry(added="2026-01-01")], tmp_json)
        assert code == 1
        assert "ISO 8601" in out

    def test_invalid_timestamp_no_timezone(self, tmp_json):
        code, out = run([make_import_entry(added="2026-01-01T00:00:00")], tmp_json)
        assert code == 1

    def test_invalid_timestamp_freeform(self, tmp_json):
        code, out = run([make_import_entry(added="January 1 2026")], tmp_json)
        assert code == 1


# ── Duplicate detection ───────────────────────────────────────────────────────

class TestDuplicateDetection:
    def test_duplicate_target_name(self, tmp_json):
        entries = [
            make_import_entry(target_name="same", source_url="https://gitlab.com/foo/a"),
            make_import_entry(target_name="same", source_url="https://gitlab.com/foo/b"),
        ]
        code, out = run(entries, tmp_json)
        assert code == 1
        assert "duplicate target_name" in out

    def test_duplicate_source_url(self, tmp_json):
        entries = [
            make_import_entry(target_name="repo-a", source_url="https://gitlab.com/foo/bar"),
            make_import_entry(target_name="repo-b", source_url="https://gitlab.com/foo/bar"),
        ]
        code, out = run(entries, tmp_json)
        assert code == 1
        assert "duplicate source_url" in out

    def test_no_false_positive_similar_names(self, tmp_json):
        entries = [
            make_import_entry(target_name="repo", source_url="https://gitlab.com/foo/a"),
            make_import_entry(target_name="repo-fork", source_url="https://gitlab.com/foo/b"),
        ]
        code, _ = run(entries, tmp_json)
        assert code == 0


# ── JSON structure ────────────────────────────────────────────────────────────

class TestJsonStructure:
    def test_invalid_json(self, tmp_path):
        p = tmp_path / "bad.json"
        p.write_text('[{"source_url": "https://gitlab.com/foo/bar"')
        code, out = run_validator("validate-registered-imports.py", str(p))
        assert code == 1
        assert "not valid JSON" in out

    def test_object_instead_of_array(self, tmp_json):
        path = tmp_json({"source_url": "https://gitlab.com/foo/bar"})
        code, out = run_validator("validate-registered-imports.py", path)
        assert code == 1
        assert "array" in out

    def test_array_with_non_object_entry(self, tmp_json):
        path = tmp_json(["not-an-object"])
        code, out = run_validator("validate-registered-imports.py", path)
        assert code == 1

    def test_missing_file(self, tmp_path):
        code, out = run_validator(
            "validate-registered-imports.py",
            str(tmp_path / "nonexistent.json")
        )
        assert code == 1
        assert "not found" in out

    def test_multiple_errors_reported(self, tmp_json):
        # Both entries are missing required fields — the validator accumulates
        # errors across entries even when it skips deeper checks per entry.
        entry_a = make_import_entry()
        del entry_a["platform"]
        entry_b = make_import_entry(target_name="repo-b", source_url="https://gitlab.com/foo/b")
        del entry_b["added"]
        code, out = run_validator("validate-registered-imports.py", tmp_json([entry_a, entry_b]))
        assert code == 1
        assert out.count("✗") >= 2
