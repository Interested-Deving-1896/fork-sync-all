"""Tests for scripts/validate-workflow-shell.py."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import textwrap


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / "scripts" / "validate-workflow-shell.py"

spec = importlib.util.spec_from_file_location("validate_workflow_shell", SCRIPT_PATH)
validator = importlib.util.module_from_spec(spec)
assert spec and spec.loader
sys.modules[spec.name] = validator
spec.loader.exec_module(validator)


def write_workflow(tmp_path: Path, run: str, *, shell: str | None = None) -> Path:
    workflow = {
        "name": "Fixture",
        "on": ["push"],
        "jobs": {
            "test": {
                "runs-on": "ubuntu-latest",
                "steps": [
                    {
                        "name": "Exercise shell",
                        "run": textwrap.dedent(run),
                        **({"shell": shell} if shell else {}),
                    }
                ],
            }
        },
    }
    path = tmp_path / "fixture.yml"
    import yaml

    path.write_text(yaml.safe_dump(workflow, sort_keys=False), encoding="utf-8")
    return path


def test_rejects_heredoc_terminator_with_pipeline(tmp_path):
    path = write_workflow(
        tmp_path,
        """
        python3 - << 'PYEOF'
        print('one')
        PYEOF | while read -r line; do
          echo "$line"
        done
        """,
    )

    checked, errors = validator.validate_workflows([path])

    assert checked == 1
    assert len(errors) == 1
    assert "here-document" in errors[0].diagnostic
    assert "delimited by end-of-file" in errors[0].diagnostic


def test_accepts_pipeline_on_heredoc_opener(tmp_path):
    path = write_workflow(
        tmp_path,
        """
        python3 - << 'PYEOF' | while read -r line; do
        print('one')
        PYEOF
          echo "$line"
        done
        """,
    )

    checked, errors = validator.validate_workflows([path])

    assert checked == 1
    assert errors == []


def test_rejects_regular_bash_syntax_error(tmp_path):
    path = write_workflow(tmp_path, "if true; then\n  echo missing-fi\n")

    checked, errors = validator.validate_workflows([path])

    assert checked == 1
    assert len(errors) == 1
    assert "syntax error" in errors[0].diagnostic


def test_skips_explicit_non_shell_interpreter(tmp_path):
    path = write_workflow(tmp_path, "print('not Bash syntax')\n", shell="python")

    checked, errors = validator.validate_workflows([path])

    assert checked == 0
    assert errors == []


def test_current_repository_workflows_are_shell_syntax_clean():
    paths = validator.workflow_paths([str(REPO_ROOT / ".github" / "workflows")])

    checked, errors = validator.validate_workflows(paths)

    assert checked > 800
    assert errors == []
