"""Security and archive-contract tests for FSA support bundles."""

import json
import os
from pathlib import Path
import subprocess
import zipfile

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/support-bundle.py"
CONFIG = ROOT / "config/support-bundle.yml"


def run_bundle(*args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(SCRIPT), *args],
        cwd=ROOT,
        env={**os.environ, **(env or {})},
        capture_output=True,
        text=True,
        check=False,
    )


def create_minimal(tmp_path: Path) -> tuple[dict, Path]:
    result = run_bundle("create", "--profile", "minimal", "--output", str(tmp_path))
    assert result.returncode == 0, result.stdout + result.stderr
    payload = json.loads(result.stdout)
    return payload, Path(payload["path"])


def test_create_and_inspect_minimal_bundle(tmp_path: Path) -> None:
    created, archive = create_minimal(tmp_path)
    inspected = run_bundle("inspect", str(archive))

    assert inspected.returncode == 0, inspected.stdout
    report = json.loads(inspected.stdout)
    assert report["ok"] is True
    assert report["bundle_id"] == created["bundle_id"]
    assert report["verified_files"] >= 4
    assert Path(created["sha256_path"]).is_file()


def test_full_bundle_redacts_allowlisted_logs_and_environment_secrets(tmp_path: Path) -> None:
    log_dir = ROOT / "artifacts/logs"
    created_artifacts_dir = not log_dir.parent.exists()
    created_log_dir = not log_dir.exists()
    log_dir.mkdir(parents=True, exist_ok=True)
    log_path = log_dir / "pytest-support-bundle.log"
    secret = "github_pat_SUPERSECRET0123456789"
    log_path.write_text(f"Authorization: Bearer {secret}\napi_key={secret}\n")

    config = yaml.safe_load(CONFIG.read_text())
    config["profiles"]["full"]["collectors"] = ["metadata", "logs"]
    config["log_paths"] = ["artifacts/logs/pytest-support-bundle.log"]
    config_path = tmp_path / "support-bundle.yml"
    config_path.write_text(yaml.safe_dump(config, sort_keys=False))
    try:
        result = run_bundle(
            "--config",
            str(config_path),
            "create",
            "--profile",
            "full",
            "--output",
            str(tmp_path / "output"),
            env={"PYTEST_API_TOKEN": secret},
        )
    finally:
        log_path.unlink(missing_ok=True)
        if created_log_dir:
            log_dir.rmdir()
        if created_artifacts_dir:
            log_dir.parent.rmdir()

    assert result.returncode == 0, result.stdout + result.stderr
    archive = Path(json.loads(result.stdout)["path"])
    with zipfile.ZipFile(archive) as bundle:
        combined = b"\n".join(bundle.read(name) for name in bundle.namelist())
        report_name = next(name for name in bundle.namelist() if name.endswith("redaction-report.json"))
        report = json.loads(bundle.read(report_name))

    assert secret.encode() not in combined
    assert b"[REDACTED]" in combined
    assert report["redacted"] >= 2


def test_inspect_detects_tampered_file(tmp_path: Path) -> None:
    _, archive = create_minimal(tmp_path)
    tampered = tmp_path / "tampered.zip"
    with zipfile.ZipFile(archive) as source, zipfile.ZipFile(tampered, "w") as target:
        for info in source.infolist():
            data = source.read(info.filename)
            if info.filename.endswith("metadata.json"):
                data += b"tampered"
            target.writestr(info, data)

    result = run_bundle("inspect", str(tampered))
    report = json.loads(result.stdout)

    assert result.returncode == 1
    assert report["ok"] is False
    assert any("checksum mismatch" in error for error in report["errors"])


def test_inspect_rejects_unlisted_archive_entry(tmp_path: Path) -> None:
    _, archive = create_minimal(tmp_path)
    tampered = tmp_path / "extra-entry.zip"
    with zipfile.ZipFile(archive) as source, zipfile.ZipFile(tampered, "w") as target:
        for info in source.infolist():
            target.writestr(info, source.read(info.filename))
        prefix = source.namelist()[0].split("/", 1)[0]
        target.writestr(f"{prefix}/unverified.txt", b"not in the manifest")

    result = run_bundle("inspect", str(tampered))
    report = json.loads(result.stdout)

    assert result.returncode == 1
    assert any("unlisted archive entry" in error for error in report["errors"])


def test_http_transport_rejects_plain_http(tmp_path: Path) -> None:
    _, archive = create_minimal(tmp_path)
    result = run_bundle(
        "send",
        str(archive),
        "--transport",
        "http",
        "--destination",
        "http://support.invalid/upload",
    )

    assert result.returncode == 1
    assert "allowed absolute URL scheme" in json.loads(result.stdout)["error"]


def test_inspect_rejects_suspicious_compression_ratio(tmp_path: Path) -> None:
    archive = tmp_path / "zip-bomb.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
        bundle.writestr("bundle/payload.txt", b"0" * (2 * 1024 * 1024))

    result = run_bundle("inspect", str(archive))

    assert result.returncode == 1
    assert "suspicious compression ratio" in json.loads(result.stdout)["error"]


def test_local_transport_creates_directory_destination(tmp_path: Path) -> None:
    _, archive = create_minimal(tmp_path / "source")
    destination = tmp_path / "downloads"
    result = run_bundle(
        "send",
        str(archive),
        "--transport",
        "local",
        "--destination",
        f"{destination}{os.sep}",
    )

    assert result.returncode == 0, result.stdout
    assert (destination / archive.name).is_file()
    assert (destination / f"{archive.name}.sha256").is_file()


def test_api_local_send_is_confined_to_workspace() -> None:
    adapter = (ROOT / "fsa-api/core/adapters/support-bundles/send.sh").read_text()

    assert "local destination must be inside the workspace" in adapter
    assert 'case "$destination_real" in "$workspace_real"/*)' in adapter
    assert "FSA_SUPPORT_UPLOAD_URL" in adapter
    assert "destination does not match the configured support endpoint" in adapter
