"""Unit tests for the report-only GitHub evidence adapter."""
import base64
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "report_agent_evidence_pr", ROOT / "scripts" / "report-agent-evidence-pr.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def test_decode_github_contents_payload():
    evidence = b'{"schema_version":"1.0.0"}'
    payload = json.dumps({"content": base64.b64encode(evidence).decode("ascii")})
    assert MODULE.decode_contents_response(payload) == evidence


def test_decode_rejects_missing_content():
    try:
        MODULE.decode_contents_response(json.dumps({"name": "evidence.json"}))
    except ValueError as exc:
        assert "no base64 content" in str(exc)
    else:
        raise AssertionError("missing content must be rejected")
