"""
Shared fixtures and helpers for the fork-sync-all validator test suite.
"""

import json
import os
import sys
import textwrap
import tempfile
import pytest

# Make scripts/ importable without installing anything
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS_DIR = os.path.join(REPO_ROOT, "scripts")
if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)


# ── File helpers ──────────────────────────────────────────────────────────────

@pytest.fixture
def tmp_json(tmp_path):
    """Write a Python object to a temp JSON file; return the path."""
    def _write(data, filename="test.json"):
        p = tmp_path / filename
        p.write_text(json.dumps(data))
        return str(p)
    return _write


@pytest.fixture
def tmp_yaml(tmp_path):
    """Write a YAML string to a temp file; return the path."""
    def _write(content, filename="test.yml"):
        p = tmp_path / filename
        p.write_text(textwrap.dedent(content))
        return str(p)
    return _write


@pytest.fixture
def tmp_file(tmp_path):
    """Write arbitrary text to a temp file; return the path."""
    def _write(content, filename="test.txt"):
        p = tmp_path / filename
        p.write_text(content)
        return str(p)
    return _write


# ── Script runner helper ──────────────────────────────────────────────────────

def run_validator(script_name, *args):
    """
    Run a validator script in-process by manipulating sys.argv and
    capturing SystemExit. Returns (exit_code, stdout_lines).

    Uses subprocess to avoid sys.argv/sys.exit pollution between tests.
    """
    import subprocess
    script = os.path.join(SCRIPTS_DIR, script_name)
    result = subprocess.run(
        [sys.executable, script] + list(args),
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )
    return result.returncode, result.stdout + result.stderr


@pytest.fixture
def validator():
    """Return the run_validator helper for use in tests."""
    return run_validator


# ── Sample data builders ──────────────────────────────────────────────────────

def make_import_entry(**overrides):
    """Return a valid registered-imports entry with optional field overrides."""
    base = {
        "source_url": "https://gitlab.com/foo/bar",
        "target_name": "bar",
        "platform": "gitlab",
        "added": "2026-01-01T00:00:00Z",
    }
    base.update(overrides)
    return base


def make_cost_profile(**overrides):
    """Return a valid cost profile YAML block string."""
    fields = {
        "rest_calls": 10,
        "graphql_calls": 0,
        "gitlab_calls": 0,
        "ai_calls": 0,
        "scales_with": "null",
        "scale_factor": 0,
        "minimum_rest_budget": 10,
    }
    fields.update(overrides)
    lines = ["profiles:", "  test-workflow:"]
    for k, v in fields.items():
        lines.append(f"    {k}: {v}")
    return "\n".join(lines) + "\n"


def make_manifest_profile(name="full", description="All files", includes=None, excludes=None):
    """Return a valid template-manifest YAML string with one profile."""
    includes = includes or [".github/workflows/*.yml"]
    excludes = excludes or []
    lines = ["profiles:", f"  {name}:", f"    description: {description}", "    include:"]
    for inc in includes:
        lines.append(f"      - {inc}")
    if excludes:
        lines.append("    exclude:")
        for exc in excludes:
            lines.append(f"      - {exc}")
    return "\n".join(lines) + "\n"


def make_consumer(name="my-repo", profile="full", **extras):
    """Return a valid template-consumers YAML string with one consumer."""
    lines = ["consumers:", f"  - name: {name}", f"    profile: {profile}"]
    for k, v in extras.items():
        lines.append(f"    {k}: {v}")
    return "\n".join(lines) + "\n"
