#!/usr/bin/env python3
"""Validate FSA agent contribution evidence without granting repository authority."""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import yaml
import jsonschema

SHA_RE = re.compile(r"^[0-9a-f]{40,64}$")
SCOPES = {"documentation", "tests", "application", "workflow", "configuration", "security", "infrastructure", "mixed"}
STATUSES = {"passed", "failed", "skipped", "unknown"}
RISK_LEVELS = {"low", "medium", "high", "critical"}


def _timestamp(value: object) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            return None
        return parsed.astimezone(timezone.utc)
    except ValueError:
        return None


def validate_evidence(evidence: object, policy: dict, now: datetime | None = None) -> list[str]:
    errors: list[str] = []
    schema_errors: list[str] = []
    schema_path = Path(__file__).resolve().parents[1] / "config/schemas/agent-contribution-evidence.schema.json"
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        schema_errors = sorted(jsonschema.Draft202012Validator(
            schema, format_checker=jsonschema.FormatChecker()
        ).iter_errors(evidence), key=lambda error: list(error.path))
        schema_errors = [f"schema: {error.message}" for error in schema_errors]
    except (OSError, json.JSONDecodeError, jsonschema.SchemaError) as exc:
        return [f"unable to validate evidence schema: {exc}"]
    if not isinstance(evidence, dict):
        return ["evidence must be a JSON object"]

    required = ("schema_version", "evidence_id", "created_at", "repository", "pull_request",
                "accountable_human", "agent", "change", "provenance", "validations", "tests", "risk")
    for key in required:
        if key not in evidence:
            errors.append(f"missing required field: {key}")
    if errors:
        return errors
    if evidence["schema_version"] != "1.0.0":
        errors.append("unsupported schema_version (expected 1.0.0)")
    if not isinstance(evidence["evidence_id"], str) or len(evidence["evidence_id"]) < 8:
        errors.append("evidence_id must be a string of at least 8 characters")
    if not isinstance(evidence["repository"], str) or not re.fullmatch(r"[^/\s]+/[^/\s]+", evidence["repository"]):
        errors.append("repository must be owner/name")
    created = _timestamp(evidence["created_at"])
    current = now or datetime.now(timezone.utc)
    if created is None:
        errors.append("created_at must be an ISO-8601 timestamp with timezone")
    else:
        max_age = int(policy.get("max_evidence_age_hours", 72))
        if created > current + timedelta(minutes=5):
            errors.append("evidence timestamp is in the future")
        elif current - created > timedelta(hours=max_age):
            errors.append(f"evidence is stale (maximum age: {max_age} hours)")

    pr = evidence["pull_request"]
    if not isinstance(pr, dict):
        errors.append("pull_request must be an object")
        pr = {}
    head_sha = pr.get("head_sha")
    if not isinstance(pr.get("number"), int) or pr["number"] < 1:
        errors.append("pull_request.number must be a positive integer")
    if not isinstance(head_sha, str) or not SHA_RE.fullmatch(head_sha):
        errors.append("pull_request.head_sha must be a 40-64 character lowercase hexadecimal SHA")
    for field in ("url", "base_ref", "head_ref"):
        if not isinstance(pr.get(field), str) or not pr[field]:
            errors.append(f"pull_request.{field} is required")

    human = evidence["accountable_human"]
    if not isinstance(human, dict) or not isinstance(human.get("login"), str) or not human["login"].strip():
        errors.append("accountable_human.login is required")
    agent = evidence["agent"]
    if not isinstance(agent, dict) or not all(isinstance(agent.get(k), str) and agent[k].strip() for k in ("provider", "agent_id")):
        errors.append("agent.provider and agent.agent_id are required")

    change = evidence["change"]
    if not isinstance(change, dict):
        errors.append("change must be an object")
        change = {}
    if not isinstance(change.get("summary"), str) or not change["summary"].strip():
        errors.append("change.summary is required")
    if change.get("scope") not in SCOPES:
        errors.append("change.scope is invalid")
    paths = change.get("changed_paths")
    if not isinstance(paths, list) or not paths or not all(isinstance(p, str) and p for p in paths):
        errors.append("change.changed_paths must be a non-empty string array")

    events = evidence["provenance"]
    if not isinstance(events, list) or not events:
        errors.append("provenance must contain at least one event")
    else:
        previous = None
        for index, event in enumerate(events):
            if not isinstance(event, dict):
                errors.append(f"provenance[{index}] must be an object")
                continue
            for field in ("event_id", "actor_id", "action"):
                if not isinstance(event.get(field), str) or not event[field]:
                    errors.append(f"provenance[{index}].{field} is required")
            if event.get("actor_type") not in {"human", "agent", "system"}:
                errors.append(f"provenance[{index}].actor_type is invalid")
            ts = _timestamp(event.get("timestamp"))
            if ts is None:
                errors.append(f"provenance[{index}].timestamp must include a timezone")
            elif previous and ts < previous:
                errors.append("provenance events must be ordered by timestamp")
            if ts:
                previous = ts

    validations = evidence["validations"]
    if not isinstance(validations, list):
        errors.append("validations must be an array")
        validations = []
    by_check = {}
    for index, item in enumerate(validations):
        if not isinstance(item, dict):
            errors.append(f"validations[{index}] must be an object")
            continue
        check_id = item.get("check_id")
        if not isinstance(check_id, str) or not check_id:
            errors.append(f"validations[{index}].check_id is required")
            continue
        if check_id in by_check:
            errors.append(f"duplicate validation check: {check_id}")
        by_check[check_id] = item
        if item.get("status") not in STATUSES:
            errors.append(f"validations[{index}].status is invalid")
        if not isinstance(item.get("commit_sha"), str) or not SHA_RE.fullmatch(item["commit_sha"]):
            errors.append(f"validations[{index}].commit_sha is invalid")
        completed = _timestamp(item.get("completed_at"))
        if completed is None:
            errors.append(f"validations[{index}].completed_at must include a timezone")
        else:
            max_age = int(policy.get("max_evidence_age_hours", 72))
            if completed > current + timedelta(minutes=5):
                errors.append(f"validation {check_id} completion timestamp is in the future")
            elif current - completed > timedelta(hours=max_age):
                errors.append(f"validation {check_id} is stale (maximum age: {max_age} hours)")
        if policy.get("require_pull_request_head_match", True) and head_sha and item.get("commit_sha") != head_sha:
            errors.append(f"validation {check_id} does not match PR head SHA")

    for check in policy.get("required_checks", []):
        item = by_check.get(check)
        if not item:
            errors.append(f"required validation missing: {check}")
        elif item.get("status") != "passed":
            errors.append(f"required validation not passed: {check}")

    tests = evidence["tests"]
    minimum = int(policy.get("minimum_test_results", 1))
    if not isinstance(tests, list):
        errors.append("tests must be an array")
        tests = []
    if len(tests) < minimum:
        errors.append(f"insufficient test results: {len(tests)} < {minimum}")
    for index, test in enumerate(tests):
        if not isinstance(test, dict) or not isinstance(test.get("name"), str) or test.get("status") not in STATUSES:
            errors.append(f"tests[{index}] is malformed")
        elif test["status"] != "passed":
            errors.append(f"test did not pass: {test['name']}")

    risk = evidence["risk"]
    if not isinstance(risk, dict) or risk.get("level") not in RISK_LEVELS or not isinstance(risk.get("factors"), list):
        errors.append("risk.level or risk.factors is invalid")
    elif risk["level"] in {"high", "critical"}:
        errors.append(f"{risk['level']} risk requires maintainer review")

    if isinstance(paths, list):
        prefixes = policy.get("risk", {}).get("sensitive_path_prefixes", [])
        sensitive = [p for p in paths if any(p.startswith(prefix) for prefix in prefixes)]
        if sensitive:
            errors.append("sensitive paths require maintainer review: " + ", ".join(sensitive))

    usage = evidence.get("resource_usage")
    if usage is None:
        if policy.get("require_resource_usage", False):
            errors.append("resource_usage is required by policy")
    elif not isinstance(usage, dict):
        errors.append("resource_usage must be an object")
    else:
        budget_path = Path(__file__).resolve().parents[1] / "config/agent-budget.yml"
        try:
            budget_config = yaml.safe_load(budget_path.read_text(encoding="utf-8")) or {}
            pool = usage.get("provider_pool")
            provider = (
                budget_config.get("providers", {}).get(pool)
                if isinstance(pool, str) else None
            )
        except (OSError, yaml.YAMLError, AttributeError) as exc:
            provider = None
            errors.append(f"unable to load provider budget configuration: {exc}")
        if not provider:
            errors.append(f"resource_usage provider_pool is not configured: {usage.get('provider_pool')}")
        elif usage.get("unit") != provider.get("unit"):
            errors.append(
                f"resource_usage unit does not match configured provider pool "
                f"({provider.get('unit')})"
            )
        observed = _timestamp(usage.get("observed_at"))
        if observed is None:
            errors.append("resource_usage.observed_at must include a timezone")
        else:
            max_age = int(policy.get("max_resource_observation_age_hours", 72))
            if observed > current + timedelta(minutes=5):
                errors.append("resource usage observation timestamp is in the future")
            elif current - observed > timedelta(hours=max_age):
                errors.append(f"resource usage observation is stale (maximum age: {max_age} hours)")
        budget_state = usage.get("budget_state")
        if isinstance(budget_state, str):
            if budget_state in {"paused", "unknown"}:
                errors.append(f"provider budget state blocks readiness: {budget_state}")
            elif budget_state == "near_limit":
                errors.append("provider budget is near its limit; maintainer review required")

    review = evidence.get("human_review")
    if review is not None and not isinstance(review, dict):
        errors.append("human_review must be a human-authored object")
    # A review record is metadata only. It never changes this evaluator's authority.
    return errors + schema_errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--policy", type=Path, default=Path("config/agent-accountability-policy.yml"))
    args = parser.parse_args()
    try:
        evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
        policy = yaml.safe_load(args.policy.read_text(encoding="utf-8")) or {}
    except (OSError, json.JSONDecodeError, yaml.YAMLError) as exc:
        print(f"[agent-evidence] unable to load input: {exc}", file=sys.stderr)
        return 2
    errors = validate_evidence(evidence, policy)
    if errors:
        print("[agent-evidence] NOT REVIEW-READY", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("[agent-evidence] evidence satisfies configured readiness checks")
    print("[agent-evidence] this is not a human approval or merge authorization")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
