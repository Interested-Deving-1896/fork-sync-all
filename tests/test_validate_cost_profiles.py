"""Tests for scripts/validate-cost-profiles.py"""

import pytest
from conftest import make_cost_profile, run_validator


def run(yaml_content, tmp_yaml):
    path = tmp_yaml(yaml_content)
    code, out = run_validator("validate-cost-profiles.py", path)
    return code, out


# ── Valid cases ───────────────────────────────────────────────────────────────

class TestValidCases:
    def test_minimal_valid_profile(self, tmp_yaml):
        code, out = run(make_cost_profile(), tmp_yaml)
        assert code == 0
        assert "1 profile(s) valid" in out

    def test_scales_with_variable(self, tmp_yaml):
        code, _ = run(make_cost_profile(
            scales_with="REPO_COUNT",
            scale_factor=5,
            minimum_rest_budget=50,
        ), tmp_yaml)
        assert code == 0

    def test_scales_with_tilde_null(self, tmp_yaml):
        code, _ = run(make_cost_profile(scales_with="~", scale_factor=0), tmp_yaml)
        assert code == 0

    def test_all_zero_calls(self, tmp_yaml):
        code, _ = run(make_cost_profile(
            rest_calls=0, graphql_calls=0, gitlab_calls=0, ai_calls=0,
            minimum_rest_budget=0,
        ), tmp_yaml)
        assert code == 0

    def test_optional_notes_field(self, tmp_yaml):
        yaml = make_cost_profile() + "    notes: some note here\n"
        code, _ = run(yaml, tmp_yaml)
        assert code == 0

    def test_optional_actual_fields(self, tmp_yaml):
        yaml = (
            make_cost_profile()
            + "    actual_rest_calls: 8\n"
            + "    actual_duration_s: 30\n"
            + "    rest_cost: 8\n"
            + "    graphql_cost: 0\n"
        )
        code, _ = run(yaml, tmp_yaml)
        assert code == 0

    def test_multiple_profiles(self, tmp_yaml):
        yaml = (
            "profiles:\n"
            "  profile-a:\n"
            "    rest_calls: 5\n"
            "    graphql_calls: 0\n"
            "    gitlab_calls: 0\n"
            "    ai_calls: 0\n"
            "    scales_with: null\n"
            "    scale_factor: 0\n"
            "    minimum_rest_budget: 5\n"
            "  profile-b:\n"
            "    rest_calls: 20\n"
            "    graphql_calls: 2\n"
            "    gitlab_calls: 0\n"
            "    ai_calls: 0\n"
            "    scales_with: FORK_COUNT\n"
            "    scale_factor: 3\n"
            "    minimum_rest_budget: 20\n"
        )
        code, out = run(yaml, tmp_yaml)
        assert code == 0
        assert "2 profile(s) valid" in out

    def test_minimum_rest_budget_equals_rest_calls(self, tmp_yaml):
        code, _ = run(make_cost_profile(rest_calls=15, minimum_rest_budget=15), tmp_yaml)
        assert code == 0

    def test_minimum_rest_budget_greater_than_rest_calls(self, tmp_yaml):
        code, _ = run(make_cost_profile(rest_calls=10, minimum_rest_budget=100), tmp_yaml)
        assert code == 0

    def test_profile_name_with_hyphens(self, tmp_yaml):
        yaml = (
            "profiles:\n"
            "  my-workflow-name:\n"
            "    rest_calls: 1\n"
            "    graphql_calls: 0\n"
            "    gitlab_calls: 0\n"
            "    ai_calls: 0\n"
            "    scales_with: null\n"
            "    scale_factor: 0\n"
            "    minimum_rest_budget: 1\n"
        )
        code, _ = run(yaml, tmp_yaml)
        assert code == 0

    def test_profile_name_with_underscores(self, tmp_yaml):
        yaml = (
            "profiles:\n"
            "  my_workflow_name:\n"
            "    rest_calls: 1\n"
            "    graphql_calls: 0\n"
            "    gitlab_calls: 0\n"
            "    ai_calls: 0\n"
            "    scales_with: null\n"
            "    scale_factor: 0\n"
            "    minimum_rest_budget: 1\n"
        )
        code, _ = run(yaml, tmp_yaml)
        assert code == 0

    def test_inline_comment_ignored(self, tmp_yaml):
        yaml = (
            "profiles:\n"
            "  test-workflow:\n"
            "    rest_calls: 10  # per repo\n"
            "    graphql_calls: 0\n"
            "    gitlab_calls: 0\n"
            "    ai_calls: 0\n"
            "    scales_with: null\n"
            "    scale_factor: 0\n"
            "    minimum_rest_budget: 10\n"
        )
        code, _ = run(yaml, tmp_yaml)
        assert code == 0


# ── Missing required fields ───────────────────────────────────────────────────

class TestMissingFields:
    @pytest.mark.parametrize("field", [
        "rest_calls", "graphql_calls", "gitlab_calls", "ai_calls",
        "scale_factor", "minimum_rest_budget", "scales_with",
    ])
    def test_missing_required_field(self, tmp_yaml, field):
        # Build YAML without the target field
        fields = {
            "rest_calls": 10,
            "graphql_calls": 0,
            "gitlab_calls": 0,
            "ai_calls": 0,
            "scales_with": "null",
            "scale_factor": 0,
            "minimum_rest_budget": 10,
        }
        del fields[field]
        lines = ["profiles:", "  test-workflow:"]
        for k, v in fields.items():
            lines.append(f"    {k}: {v}")
        yaml = "\n".join(lines) + "\n"
        code, out = run(yaml, tmp_yaml)
        assert code == 1
        assert field in out


# ── Integer field validation ──────────────────────────────────────────────────

class TestIntegerFields:
    @pytest.mark.parametrize("field", [
        "rest_calls", "graphql_calls", "gitlab_calls", "ai_calls",
        "scale_factor", "minimum_rest_budget",
    ])
    def test_negative_value_rejected(self, tmp_yaml, field):
        code, out = run(make_cost_profile(**{field: -1}), tmp_yaml)
        assert code == 1
        assert field in out

    @pytest.mark.parametrize("field", [
        "rest_calls", "graphql_calls", "gitlab_calls", "ai_calls",
        "scale_factor", "minimum_rest_budget",
    ])
    def test_non_integer_value_rejected(self, tmp_yaml, field):
        code, out = run(make_cost_profile(**{field: "abc"}), tmp_yaml)
        assert code == 1
        assert field in out

    def test_float_value_rejected(self, tmp_yaml):
        code, out = run(make_cost_profile(rest_calls=1.5), tmp_yaml)
        assert code == 1
        assert "rest_calls" in out

    def test_zero_is_valid_for_all_int_fields(self, tmp_yaml):
        code, _ = run(make_cost_profile(
            rest_calls=0, graphql_calls=0, gitlab_calls=0, ai_calls=0,
            scale_factor=0, minimum_rest_budget=0,
        ), tmp_yaml)
        assert code == 0


# ── scales_with / scale_factor consistency ────────────────────────────────────

class TestScalesWithConsistency:
    def test_scale_factor_nonzero_when_scales_with_null(self, tmp_yaml):
        code, out = run(make_cost_profile(scales_with="null", scale_factor=3), tmp_yaml)
        assert code == 1
        assert "scale_factor" in out

    def test_scale_factor_nonzero_when_scales_with_tilde(self, tmp_yaml):
        code, out = run(make_cost_profile(scales_with="~", scale_factor=2), tmp_yaml)
        assert code == 1
        assert "scale_factor" in out

    def test_scale_factor_zero_when_scales_with_null_ok(self, tmp_yaml):
        code, _ = run(make_cost_profile(scales_with="null", scale_factor=0), tmp_yaml)
        assert code == 0

    def test_scales_with_invalid_identifier(self, tmp_yaml):
        code, out = run(make_cost_profile(scales_with="123bad"), tmp_yaml)
        assert code == 1
        assert "scales_with" in out

    def test_scales_with_hyphen_rejected(self, tmp_yaml):
        # Variable names can't have hyphens
        code, out = run(make_cost_profile(
            scales_with="REPO-COUNT", scale_factor=1, minimum_rest_budget=10
        ), tmp_yaml)
        assert code == 1
        assert "scales_with" in out

    def test_scales_with_valid_variable_name(self, tmp_yaml):
        code, _ = run(make_cost_profile(
            scales_with="REPO_COUNT", scale_factor=2, minimum_rest_budget=20
        ), tmp_yaml)
        assert code == 0


# ── minimum_rest_budget constraint ───────────────────────────────────────────

class TestMinimumRestBudget:
    def test_budget_less_than_rest_calls(self, tmp_yaml):
        code, out = run(make_cost_profile(rest_calls=20, minimum_rest_budget=5), tmp_yaml)
        assert code == 1
        assert "minimum_rest_budget" in out

    def test_budget_zero_when_rest_calls_zero(self, tmp_yaml):
        code, _ = run(make_cost_profile(rest_calls=0, minimum_rest_budget=0), tmp_yaml)
        assert code == 0

    def test_budget_one_less_than_rest_calls(self, tmp_yaml):
        code, out = run(make_cost_profile(rest_calls=10, minimum_rest_budget=9), tmp_yaml)
        assert code == 1


# ── Profile name validation ───────────────────────────────────────────────────

class TestProfileNameValidation:
    def test_name_starting_with_digit_accepted(self, tmp_yaml):
        # PROFILE_NAME_RE allows leading digits — validator accepts these names
        yaml = (
            "profiles:\n"
            "  1bad-name:\n"
            "    rest_calls: 1\n"
            "    graphql_calls: 0\n"
            "    gitlab_calls: 0\n"
            "    ai_calls: 0\n"
            "    scales_with: null\n"
            "    scale_factor: 0\n"
            "    minimum_rest_budget: 1\n"
        )
        code, _ = run(yaml, tmp_yaml)
        assert code == 0


# ── File-level errors ─────────────────────────────────────────────────────────

class TestFileLevelErrors:
    def test_missing_file(self, tmp_path):
        code, out = run_validator(
            "validate-cost-profiles.py",
            str(tmp_path / "nonexistent.yml")
        )
        assert code == 1
        assert "not found" in out

    def test_no_profiles_section(self, tmp_yaml):
        code, out = run("other_key:\n  foo: bar\n", tmp_yaml)
        assert code == 1
        assert "no profiles" in out

    def test_empty_profiles_section(self, tmp_yaml):
        code, out = run("profiles:\n", tmp_yaml)
        assert code == 1
        assert "no profiles" in out

    def test_multiple_errors_accumulated(self, tmp_yaml):
        # Two profiles each with a different error
        yaml = (
            "profiles:\n"
            "  profile-a:\n"
            "    rest_calls: -1\n"       # negative
            "    graphql_calls: 0\n"
            "    gitlab_calls: 0\n"
            "    ai_calls: 0\n"
            "    scales_with: null\n"
            "    scale_factor: 0\n"
            "    minimum_rest_budget: 10\n"
            "  profile-b:\n"
            "    rest_calls: 5\n"
            "    graphql_calls: 0\n"
            "    gitlab_calls: 0\n"
            "    ai_calls: 0\n"
            "    scales_with: null\n"
            "    scale_factor: 3\n"      # nonzero with null scales_with
            "    minimum_rest_budget: 5\n"
        )
        code, out = run(yaml, tmp_yaml)
        assert code == 1
        assert out.count("✗") >= 2


# ── Optional integer fields ───────────────────────────────────────────────────

class TestOptionalIntegerFields:
    @pytest.mark.parametrize("field", [
        "actual_rest_calls", "actual_duration_s", "rest_cost", "graphql_cost",
    ])
    def test_optional_field_negative_rejected(self, tmp_yaml, field):
        yaml = make_cost_profile() + f"    {field}: -1\n"
        code, out = run(yaml, tmp_yaml)
        assert code == 1
        assert field in out

    @pytest.mark.parametrize("field", [
        "actual_rest_calls", "actual_duration_s", "rest_cost", "graphql_cost",
    ])
    def test_optional_field_non_integer_rejected(self, tmp_yaml, field):
        yaml = make_cost_profile() + f"    {field}: bad\n"
        code, out = run(yaml, tmp_yaml)
        assert code == 1
        assert field in out

    @pytest.mark.parametrize("field", [
        "actual_rest_calls", "actual_duration_s", "rest_cost", "graphql_cost",
    ])
    def test_optional_field_zero_accepted(self, tmp_yaml, field):
        yaml = make_cost_profile() + f"    {field}: 0\n"
        code, _ = run(yaml, tmp_yaml)
        assert code == 0
