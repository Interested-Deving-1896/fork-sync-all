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


def test_target_binding_requires_exact_repository_pr_and_head():
    evidence = {
        "repository": "owner/repo",
        "pull_request": {"number": 7, "head_sha": "a" * 40},
    }
    payload = json.dumps(evidence).encode()
    MODULE.validate_target_binding(payload, "owner/repo", "7", "a" * 40)
    for repo, number, sha in [
        ("other/repo", "7", "a" * 40),
        ("owner/repo", "8", "a" * 40),
        ("owner/repo", "7", "b" * 40),
    ]:
        try:
            MODULE.validate_target_binding(payload, repo, number, sha)
        except ValueError:
            pass
        else:
            raise AssertionError("mismatched PR identity must be rejected")


def test_parse_github_run_url_accepts_only_same_repository():
    assert MODULE.parse_github_run_url(
        "https://github.com/owner/repo/actions/runs/123", "owner/repo"
    ) == 123
    for url in [
        "https://github.com/other/repo/actions/runs/123",
        "https://example.com/owner/repo/actions/runs/123",
        "https://github.com/owner/repo/actions/runs/not-a-number",
    ]:
        try:
            MODULE.parse_github_run_url(url, "owner/repo")
        except ValueError:
            pass
        else:
            raise AssertionError("untrusted or malformed run URLs must be rejected")


def test_verify_run_references_checks_exact_sha_and_job(monkeypatch):
    evidence = {
        "validations": [
            {"check_id": "tests", "run_url": "https://github.com/owner/repo/actions/runs/123"}
        ]
    }
    policy = {
        "required_checks": ["tests"],
        "github_job_name_aliases": {"tests": ["Validator unit tests"]},
    }
    def fake_get(url, token):
        if url.endswith("/actions/runs/123"):
            return {"head_sha": "a" * 40, "status": "completed", "conclusion": "success"}
        return {"jobs": [{"name": "Validator unit tests", "status": "completed", "conclusion": "success"}]}
    monkeypatch.setattr(MODULE, "github_api_json", fake_get)
    assert MODULE.verify_run_references(
        evidence, policy, "owner/repo", "a" * 40, "token", "https://api.github.com"
    ) == []
    errors = MODULE.verify_run_references(
        evidence, policy, "owner/repo", "b" * 40, "token", "https://api.github.com"
    )
    assert any("current PR head SHA" in error for error in errors)


def test_verify_run_references_rejects_unmapped_or_failed_job(monkeypatch):
    evidence = {
        "validations": [
            {"check_id": "tests", "run_url": "https://github.com/owner/repo/actions/runs/123"}
        ]
    }
    policy = {
        "required_checks": ["tests"],
        "github_job_name_aliases": {"tests": ["Validator unit tests"]},
    }
    def fake_get(url, token):
        if url.endswith("/actions/runs/123"):
            return {"head_sha": "a" * 40, "status": "completed", "conclusion": "success"}
        return {"jobs": [{"name": "Validator unit tests", "status": "completed", "conclusion": "failure"}]}
    monkeypatch.setattr(MODULE, "github_api_json", fake_get)
    errors = MODULE.verify_run_references(
        evidence, policy, "owner/repo", "a" * 40, "token", "https://api.github.com"
    )
    assert any("did not complete successfully" in error for error in errors)
