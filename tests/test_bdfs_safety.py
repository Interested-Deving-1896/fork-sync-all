"""Safety and artifact-contract tests for the BDFS lifecycle."""

import json
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
BDFS_DEV = ROOT / "scripts/bdfs-dev.sh"
BDFS_EXPORT = ROOT / "fsa-api/core/adapters/bdfs/export.sh"


def run_script(script: Path, *args: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(script), *args],
        cwd=ROOT,
        env={**os.environ, **env},
        capture_output=True,
        text=True,
        check=False,
    )


def lifecycle_env(tmp_path: Path) -> dict[str, str]:
    return {
        "BDFS_ALLOWED_ROOTS": str(tmp_path),
        "BDFS_STATE_DIR": str(tmp_path / "state"),
        "DRY_RUN": "true",
    }


def test_dry_run_create_auto_is_non_mutating(tmp_path: Path) -> None:
    source = tmp_path / "source"
    source.mkdir()

    result = run_script(
        BDFS_DEV,
        "create",
        "--name",
        "safe-workspace",
        "--source",
        str(source),
        "--backend",
        "auto",
        env=lifecycle_env(tmp_path),
    )

    assert result.returncode == 0, result.stderr
    assert "DRY RUN: create" in result.stderr
    assert not (tmp_path / "state").exists()


def test_workspace_path_traversal_is_rejected(tmp_path: Path) -> None:
    sentinel = tmp_path / "sentinel"
    sentinel.write_text("preserve me")

    result = run_script(
        BDFS_DEV,
        "drop",
        "../../sentinel",
        "--force",
        env=lifecycle_env(tmp_path),
    )

    assert result.returncode != 0
    assert "Invalid workspace name" in result.stderr
    assert sentinel.read_text() == "preserve me"


def test_backend_modules_refuse_direct_execution() -> None:
    for name in ("bdfs-dev-btrfs.sh", "bdfs-dev-overlay.sh", "bdfs-dev-dwarfs.sh"):
        result = subprocess.run(
            ["bash", str(ROOT / "scripts" / name)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode == 64
        assert "must be sourced" in result.stderr


def test_export_dry_run_auto_writes_plan_inside_workspace(tmp_path: Path) -> None:
    target = tmp_path / "artifacts/bdfs/fsa-package"
    result = run_script(
        BDFS_EXPORT,
        env={
            "GITHUB_WORKSPACE": str(tmp_path),
            "BODY_backend": "auto",
            "BODY_target": str(target),
            "BODY_dry_run": "true",
        },
    )

    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    plan = Path(f"{target}.plan.json")
    assert payload["ok"] is True
    assert payload["dry_run"] is True
    assert payload["backend"] == "auto"
    assert json.loads(plan.read_text()) == payload


def test_export_rejects_target_outside_workspace(tmp_path: Path) -> None:
    result = run_script(
        BDFS_EXPORT,
        env={
            "GITHUB_WORKSPACE": str(tmp_path),
            "BODY_target": "/tmp/not-an-fsa-artifact",
            "BODY_dry_run": "true",
        },
    )

    assert result.returncode != 0
    assert json.loads(result.stdout)["ok"] is False


def test_mocked_dwarfs_export_produces_verified_artifact(tmp_path: Path) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    mkdwarfs = fake_bin / "mkdwarfs"
    mkdwarfs.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "out=''\n"
        "while [[ $# -gt 0 ]]; do\n"
        "  if [[ $1 == -o ]]; then out=$2; shift 2; else shift; fi\n"
        "done\n"
        "printf 'mock-dwarfs-artifact' > \"$out\"\n"
    )
    mkdwarfs.chmod(0o755)
    target = tmp_path / "artifacts/bdfs/fsa-package"

    result = run_script(
        BDFS_EXPORT,
        env={
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "GITHUB_WORKSPACE": str(tmp_path),
            "BODY_backend": "dwarfs",
            "BODY_target": str(target),
            "BODY_dry_run": "false",
        },
    )

    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    artifact = Path(payload["target"])
    assert payload["ok"] is True
    assert payload["size"] == artifact.stat().st_size
    assert artifact.read_text() == "mock-dwarfs-artifact"
    assert Path(f"{artifact}.sha256").is_file()


def test_workflows_keep_live_bdfs_behind_runner_and_stage_gates() -> None:
    package = (ROOT / ".github/workflows/bdfs-package.yml").read_text()
    full_chain = (ROOT / ".github/workflows/full-chain-flush.yml").read_text()

    assert "'ubuntu-latest' || 'bdfs-native'" in package
    assert "hashFiles('/tmp/" not in package
    assert "if-no-files-found: error" in package
    assert "if: vars.BDFS_PACKAGE_ENABLED == 'true'" in full_chain

    for name in (
        "bdfs-dev.yml",
        "bdfs-dev-btrfs.yml",
        "bdfs-dev-dwarfs.yml",
        "bdfs-dev-overlay.yml",
    ):
        workflow = (ROOT / ".github/workflows" / name).read_text()
        assert "runs-on: bdfs-native" in workflow
        assert "environment: bdfs-native" in workflow
        assert "bash scripts/bdfs-dev.sh" in workflow
