import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "scripts" / "operation_lifecycle_cli.py"


def request():
    revision = "a" * 40
    return {
        "mode": "preflight",
        "operation": {
            "schema_version": "1.0", "operation_id": "cli-op",
            "operation_type": "audit", "target": "owner/repo", "revision": revision,
            "acceptance_criteria": ["checks-pass"],
            "policy": {"required_evidence": ["source_revision"]},
        },
        "evidence": [{
            "evidence_id": "ev-source", "kind": "source_revision",
            "status": "observed", "source": "git", "revision": revision,
            "locator": "commit:" + revision,
        }],
    }


def run_cli(payload):
    return subprocess.run(
        [sys.executable, str(CLI)], input=json.dumps(payload), text=True,
        capture_output=True, check=False,
    )


def test_cli_preflight_reads_stdin_and_emits_json():
    result = run_cli(request())
    assert result.returncode == 0
    assert json.loads(result.stdout)["status"] == "ready"
    assert result.stderr == ""


def test_cli_rejects_unknown_mode_without_traceback():
    payload = request()
    payload["mode"] = "execute"
    result = run_cli(payload)
    assert result.returncode == 2
    assert json.loads(result.stderr)["status"] == "invalid_request"
    assert result.stdout == ""


def test_cli_rejects_invalid_json():
    result = subprocess.run(
        [sys.executable, str(CLI)], input="{", text=True,
        capture_output=True, check=False,
    )
    assert result.returncode == 2
    assert json.loads(result.stderr)["status"] == "invalid_request"


def test_cli_does_not_create_or_modify_request_file(tmp_path):
    source = tmp_path / "request.json"
    payload = request()
    source.write_text(json.dumps(payload), encoding="utf-8")
    before = source.read_bytes()
    result = subprocess.run(
        [sys.executable, str(CLI), "--input", str(source)],
        text=True, capture_output=True, check=False,
    )
    assert result.returncode == 0
    assert source.read_bytes() == before
    assert json.loads(result.stdout)["authority"]["mutation_performed"] is False
