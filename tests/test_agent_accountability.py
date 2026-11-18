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
                         "completed_at": stamp, "run_url": "https://github.com/Interested-Deving-1896/fork-sync-all/actions/runs/1"}
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


def test_human_review_claim_is_metadata_only():
    item = valid_evidence()
    item["human_review"] = {
        "reviewer_login": "unverified-agent-claim",
        "decision": "approved",
        "review_url": "https://github.com/Interested-Deving-1896/fork-sync-all/pull/1032",
        "reviewed_at": "2026-11-16T11:45:00Z",
    }
    # The evaluator does not use this unverified claim as approval authority.
    assert MODULE.validate_evidence(item, policy(), NOW) == []


def test_stale_validation_result_blocks():
    item = valid_evidence()
    item["validations"][0]["completed_at"] = "2026-11-01T00:00:00Z"
    errors = MODULE.validate_evidence(item, policy(), NOW)
    assert any("validation tests is stale" in error for error in errors)


def test_future_validation_result_blocks():
    item = valid_evidence()
    item["validations"][0]["completed_at"] = "2026-11-17T00:00:00Z"
    errors = MODULE.validate_evidence(item, policy(), NOW)
    assert any("completion timestamp is in the future" in error for error in errors)


def test_resource_usage_uses_existing_agent_budget_governor():
    item = valid_evidence()
    item["resource_usage"] = {
        "provider_pool": "ona",
        "unit": "ocu",
        "available_units": 50,
        "observed_at": "2026-11-16T11:45:00Z",
        "source": "test-provider-adapter",
        "mode": "ready",
        "task": "end-to-end-update",
    }
    assert MODULE.validate_evidence(item, policy(), NOW) == []


def test_resource_usage_rejects_unknown_provider():
    item = valid_evidence()
    item["resource_usage"] = {
        "provider_pool": "unknown-pool",
        "unit": "tokens",
        "available_units": 100,
        "observed_at": "2026-11-16T11:45:00Z",
        "source": "test-adapter",
        "mode": "ready",
    }
    errors = MODULE.validate_evidence(item, policy(), NOW)
    assert any("provider" in error and "not configured" in error for error in errors)


def test_resource_usage_rejects_paused_budget():
    item = valid_evidence()
    item["resource_usage"] = {
        "provider_pool": "ona",
        "unit": "ocu",
        "available_units": 25,
        "observed_at": "2026-11-16T11:45:00Z",
        "source": "test-adapter",
        "mode": "paused",
        "task": "end-to-end-update",
    }
    assert any("agent budget governor blocks readiness" in error
               for error in MODULE.validate_evidence(item, policy(), NOW))


def test_resource_usage_is_optional_until_policy_requires_it():
    item = valid_evidence()
    configured = policy()
    configured["require_resource_usage"] = True
    assert any("resource_usage is required by policy"
               for error in MODULE.validate_evidence(item, configured, NOW))


def test_resource_usage_rejects_wrong_native_unit():
    item = valid_evidence()
    item["resource_usage"] = {
        "provider_pool": "ona",
        "unit": "tokens",
        "available_units": 100,
        "observed_at": "2026-11-16T11:45:00Z",
        "source": "test-adapter",
        "mode": "ready",
    }
    assert any("unit" in error for error in MODULE.validate_evidence(item, policy(), NOW))


def test_resource_usage_rejects_stale_observation():
    item = valid_evidence()
    item["resource_usage"] = {
        "provider_pool": "openai-direct",
        "unit": "usd",
        "available_units": 100,
        "observed_at": "2026-11-01T00:00:00Z",
        "source": "test-adapter",
        "mode": "ready",
    }
    assert any("stale-observation" in error
               for error in MODULE.validate_evidence(item, policy(), NOW))


def test_malformed_budget_mode_does_not_crash_validator():
    item = valid_evidence()
    item["resource_usage"] = {
        "provider_pool": "openai-direct",
        "unit": "usd",
        "available_units": 100,
        "observed_at": "2026-11-16T11:45:00Z",
        "source": "test-adapter",
        "mode": ["ready"],
    }
    errors = MODULE.validate_evidence(item, policy(), NOW)
    assert any("schema:" in error for error in errors)


def test_malformed_nested_enums_fail_closed_without_crashing():
    cases = []
    item = valid_evidence()
    item["change"]["scope"] = ["tests"]
    cases.append(item)
    item = valid_evidence()
    item["provenance"][0]["actor_type"] = ["agent"]
    cases.append(item)
    item = valid_evidence()
    item["validations"][0]["status"] = ["passed"]
    cases.append(item)
    item = valid_evidence()
    item["tests"][0]["status"] = ["passed"]
    cases.append(item)
    item = valid_evidence()
    item["risk"]["level"] = ["low"]
    cases.append(item)
    for malformed in cases:
        errors = MODULE.validate_evidence(malformed, policy(), NOW)
        assert errors


def test_resource_usage_rejects_insufficient_task_budget():
    item = valid_evidence()
    item["resource_usage"] = {
        "provider_pool": "ona",
        "unit": "ocu",
        "available_units": 35,
        "observed_at": "2026-11-16T11:45:00Z",
        "source": "test-adapter",
        "mode": "ready",
        "task": "end-to-end-update",
    }
    assert any("insufficient-task-budget" in error
               for error in MODULE.validate_evidence(item, policy(), NOW))
