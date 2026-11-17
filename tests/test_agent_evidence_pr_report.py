"""Unit tests for the report-only GitHub evidence adapter."""
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "report_agent_evidence_pr", ROOT / "scripts" / "report-agent-evidence-pr.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def test_extract_newest_marked_evidence_comment():
    comments = [
        {
            "id": 22,
            "body": MODULE.MARKER + '\n```json\n{"evidence_id":"newer"}\n```',
            "user": {"login": "agent-bot"},
            "created_at": "2026-11-17T12:00:00Z",
            "html_url": "https://github.com/example/repo/pull/1#issuecomment-22",
        },
        {
            "id": 11,
            "body": MODULE.MARKER + '\n```json\n{"evidence_id":"older"}\n```',
            "user": {"login": "old-agent"},
        },
    ]
    evidence, metadata = MODULE.extract_evidence_comment(comments)
    assert json.loads(evidence) == {"evidence_id": "newer"}
    assert metadata["comment_id"] == 22
    assert metadata["author"] == "agent-bot"


def test_extract_returns_none_without_marker():
    assert MODULE.extract_evidence_comment([{"body": "ordinary PR comment"}]) is None


def test_extract_rejects_malformed_marked_comment():
    try:
        MODULE.extract_evidence_comment([{"body": MODULE.MARKER + "\nmissing JSON fence"}])
    except ValueError as exc:
        assert "fenced JSON" in str(exc)
    else:
        raise AssertionError("marked comments without JSON must be rejected")


def test_extract_rejects_invalid_json():
    body = MODULE.MARKER + '\n```json\nnot-json\n```'
    try:
        MODULE.extract_evidence_comment([{"body": body}])
    except json.JSONDecodeError:
        pass
    else:
        raise AssertionError("invalid JSON must be rejected")


def test_extract_rejects_oversized_evidence():
    payload = '{"value":"' + ("x" * MODULE.MAX_EVIDENCE_BYTES) + '"}'
    body = MODULE.MARKER + "\n```json\n" + payload + "\n```"
    try:
        MODULE.extract_evidence_comment([{"body": body}])
    except ValueError as exc:
        assert "256 KiB limit" in str(exc)
    else:
        raise AssertionError("oversized evidence must be rejected")
