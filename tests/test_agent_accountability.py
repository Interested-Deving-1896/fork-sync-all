"""Tests for provider-neutral agent contribution evidence readiness."""
import importlib.util
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "validate_agent_evidence", ROOT / "scripts" / "validate-agent-evidence.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

SHA = "a" * 40
NOW = datetime(2026, 11, 16, 12, 0, tzinfo=timezone.utc)


def policy():
    import yaml
    return yaml.safe_load((ROOT / "config/agent-accountability-policy.yml").read_text())


def valid_evidence():
    stamp = "2026-11-16T11:30:00Z"
    return {
        "schema_version": "1.0.0",
        "evidence_id": "evidence-0001",
        "created_at": stamp,
        "repository": "Interested-Deving-1896/fork-sync-all",
        "pull_request": {"number": 1031, "url": "https://github.com/Interested-Deving-1896/fork-sync-all/pull/1031",
                         "base_ref": "main", "head_ref": "feat/example", "head_sha": SHA},
        "accountable_human": {"login": "Interested-Deving-1896"},
        "agent": {"provider": "provider-neutral", "agent_id": "test-agent"},
        "change": {"summary": "Add evidence contract", "scope": "tests", "changed_paths": ["tests/test_agent_accountability.py"]},
        "provenance": [{"event_id": "evt-1", "timestamp": stamp, "actor_type": "agent",
                        "actor_id": "test-agent", "action": "created evidence"}],
        "validations": [{"check_id": name, "status": "passed", "commit_sha": SHA,
                         "completed_at": stamp, "run_url": "https://github.com/example/run/1"}
                        for name in ("tests", "lint", "security")],
        "tests": [{"name": "focused tests", "status": "passed", "count": 4}],
        "risk": {"level": "low", "factors": []},
    }


def test_valid_evidence_is_ready():
    assert MODULE.validate_evidence(valid_evidence(), policy(), NOW) == []


def test_missing_accountable_human_blocks():
    item = valid_evidence()
    item["accountable_human"] = {}
    assert any("accountable_human.login" in e for e in MODULE.validate_evidence(item, policy(), NOW))


def test_missing_required_validation_blocks():
    item = valid_evidence()
    item["validations"] = [v for v in item["validations"] if v["check_id"] != "security"]
    assert any("required validation missing: security" in e for e in MODULE.validate_evidence(item, policy(), NOW))


def test_failed_and_skipped_checks_block():
    item = valid_evidence()
    item["validations"][0]["status"] = "skipped"
    assert any("required validation not passed" in e for e in MODULE.validate_evidence(item, policy(), NOW))


def test_head_sha_mismatch_blocks():
    item = valid_evidence()
    item["validations"][0]["commit_sha"] = "b" * 40
    assert any("does not match PR head SHA" in e for e in MODULE.validate_evidence(item, policy(), NOW))


def test_stale_evidence_blocks():
    item = valid_evidence()
    item["created_at"] = "2026-11-01T00:00:00Z"
    assert any("evidence is stale" in e for e in MODULE.validate_evidence(item, policy(), NOW))


def test_out_of_order_provenance_blocks():
    item = valid_evidence()
    item["provenance"].append({"event_id": "evt-2", "timestamp": "2026-11-16T10:00:00Z",
                               "actor_type": "human", "actor_id": "maintainer", "action": "reviewed"})
    assert any("ordered by timestamp" in e for e in MODULE.validate_evidence(item, policy(), NOW))


def test_sensitive_paths_escalate():
    item = valid_evidence()
    item["change"]["changed_paths"] = [".github/workflows/new.yml"]
    assert any("sensitive paths require maintainer review" in e for e in MODULE.validate_evidence(item, policy(), NOW))


def test_high_risk_escalates():
    item = valid_evidence()
    item["risk"]["level"] = "high"
    assert any("high risk requires maintainer review" in e for e in MODULE.validate_evidence(item, policy(), NOW))


def test_agent_cannot_supply_approval_authority():
    item = valid_evidence()
    item["agent"]["approval"] = "approved"
    errors = MODULE.validate_evidence(item, policy(), NOW)
    assert any("Additional properties are not allowed" in error for error in errors)
