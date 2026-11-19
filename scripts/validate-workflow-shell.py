#!/usr/bin/env python3
"""Syntax-check Bash-compatible ``run:`` blocks in GitHub Actions workflows.

Parsing a workflow as YAML does not parse the embedded shell program.  This
validator loads each workflow with ``yaml.safe_load``, extracts step-level
``run`` strings, and asks Bash to parse every Bash-compatible block.

Bash notably returns success for some malformed heredocs while printing a
diagnostic such as "here-document ... delimited by end-of-file".  Diagnostics
from ``bash -n`` are therefore treated as failures even when its exit code is
zero.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import shlex
import subprocess
import sys
from typing import Any, Iterable

import yaml


REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"


@dataclass(frozen=True)
class ShellBlock:
    workflow: Path
    job: str
    step_index: int
    step_name: str
    program: str

    @property
    def location(self) -> str:
        return f"{self.workflow.name} / {self.job} / {self.step_name}"


@dataclass(frozen=True)
class ValidationError:
    location: str
    diagnostic: str


def workflow_paths(inputs: Iterable[str] | None = None) -> list[Path]:
    """Expand workflow files/directories into a deterministic file list."""
    if not inputs:
        inputs = [str(WORKFLOWS_DIR)]

    paths: set[Path] = set()
    for raw_path in inputs:
        path = Path(raw_path)
        if path.is_dir():
            paths.update(path.glob("*.yml"))
            paths.update(path.glob("*.yaml"))
        elif path.suffix in {".yml", ".yaml"}:
            paths.add(path)
    return sorted(paths)


def _shell_executable(shell: str) -> str:
    """Return the basename of a step's configured shell command."""
    try:
        words = shlex.split(shell)
    except ValueError:
        words = shell.split()
    return os.path.basename(words[0]) if words else ""


def _uses_bash_syntax(shell: Any, runs_on: Any) -> bool:
    """Whether a run block is expected to use Bash-compatible syntax."""
    if shell:
        executable = _shell_executable(str(shell)).lower()
        return executable in {"bash", "sh"} or executable.endswith(".sh")

    # Unspecified shells are Bash-compatible on GitHub-hosted Linux and macOS.
    # Windows defaults to PowerShell and must not be passed to Bash.
    runner_text = str(runs_on or "").lower()
    return "windows" not in runner_text


def extract_shell_blocks(path: Path, document: dict[str, Any]) -> list[ShellBlock]:
    """Extract Bash-compatible step-level run blocks from one workflow."""
    blocks: list[ShellBlock] = []
    workflow_shell = ((document.get("defaults") or {}).get("run") or {}).get("shell")

    jobs = document.get("jobs") or {}
    if not isinstance(jobs, dict):
        return blocks

    for job_name, job in jobs.items():
        if not isinstance(job, dict):
            continue
        job_shell = ((job.get("defaults") or {}).get("run") or {}).get("shell")
        runs_on = job.get("runs-on")
        steps = job.get("steps") or []
        if not isinstance(steps, list):
            continue

        for index, step in enumerate(steps, start=1):
            if not isinstance(step, dict) or not isinstance(step.get("run"), str):
                continue
            shell = step.get("shell") or job_shell or workflow_shell
            if not _uses_bash_syntax(shell, runs_on):
                continue
            blocks.append(
                ShellBlock(
                    workflow=path,
                    job=str(job_name),
                    step_index=index,
                    step_name=str(step.get("name") or f"step {index}"),
                    program=step["run"],
                )
            )
    return blocks


def validate_block(block: ShellBlock) -> ValidationError | None:
    """Run Bash's parser and return a structured error for any diagnostic."""
    result = subprocess.run(
        ["bash", "--noprofile", "--norc", "-n", "-s"],
        input=block.program,
        capture_output=True,
        text=True,
        check=False,
    )
    diagnostic = result.stderr.strip()
    if result.returncode == 0 and not diagnostic:
        return None
    if not diagnostic:
        diagnostic = f"bash -n exited with status {result.returncode}"
    return ValidationError(block.location, diagnostic)


def validate_workflows(paths: Iterable[Path]) -> tuple[int, list[ValidationError]]:
    """Validate files, returning the number of checked blocks and errors."""
    checked = 0
    errors: list[ValidationError] = []
    for path in paths:
        try:
            with path.open(encoding="utf-8") as workflow_file:
                document = yaml.safe_load(workflow_file) or {}
        except (OSError, yaml.YAMLError) as exc:
            errors.append(ValidationError(path.name, f"YAML load failed: {exc}"))
            continue
        if not isinstance(document, dict):
            errors.append(ValidationError(path.name, "workflow root must be a mapping"))
            continue

        for block in extract_shell_blocks(path, document):
            checked += 1
            error = validate_block(block)
            if error:
                errors.append(error)
    return checked, errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "paths",
        nargs="*",
        help="Workflow files or directories (default: .github/workflows)",
    )
    args = parser.parse_args(argv)
    paths = workflow_paths(args.paths)
    checked, errors = validate_workflows(paths)

    if errors:
        print(f"Workflow shell validation failed with {len(errors)} error(s):")
        for error in errors:
            indented = error.diagnostic.replace("\n", "\n      ")
            print(f"  - {error.location}\n      {indented}")
        return 1

    print(
        f"Workflow shell validation passed: {checked} Bash-compatible run block(s) "
        f"across {len(paths)} workflow file(s)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
